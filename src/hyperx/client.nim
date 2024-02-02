## HTTP/2 client
## WIP

{.define: ssl.}

import ./frame
import ./stream
import ./queue
import ./lock
import ./errors

when defined(hyperxTest):
  import ./testsocket

const
  preface = "PRI * HTTP/2.0\r\L\r\LSM\r\L\r\L"
  # https://httpwg.org/specs/rfc9113.html#SettingValues
  headerTableSize = 4096

template debugInfo(s: string): untyped =
  when defined(hyperxDebug):
    debugEcho s
  else:
    discard

template check(cond: bool): untyped =
  if not cond:
    raise (ref HyperxError)()

template check(cond: bool, errObj: untyped): untyped =
  if not cond:
    raise errObj

func add(s: var seq[byte], ss: string) =
  # XXX x_x
  for c in ss:
    s.add c.byte

func add(s: var string, ss: seq[byte]) =
  # XXX x_x
  for c in ss:
    s.add c.char

type
  StreamId = distinct uint32  # range[0 .. 31.ones.int]

proc `==`(a, b: StreamId): bool {.borrow.}
proc `+=`(a: var StreamId, b: StreamId) {.borrow.}

import std/tables
import std/net
import std/asyncdispatch
import std/asyncnet
import pkg/hpack

# XXX remove, move to client or make it threadlocal
var sslContext: SslContext

proc destroySslContext() {.noconv.} =
  sslContext.destroyContext()

from std/openssl import SSL_CTX_set_alpn_protos

proc defaultSslContext(): SslContext =
  if not sslContext.isNil:
    return sslContext
  # protSSLv23 will disable all protocols
  # lower than the min protocol defined
  # in openssl.config, usually +TLSv1.2
  sslContext = newContext(protSSLv23, verifyMode=CVerifyNone)
  # XXX OPENSSL_VERSION_NUMBER >= 0x10002000L
  discard SSL_CTX_set_alpn_protos(sslContext.context, "\x02h2", 3)
  # XXX catch EOutOfIndex
  addQuitProc(destroySslContext)
  return sslContext

proc decode(payload: openArray[byte], ds: var DecodedStr, dh: var DynHeaders) =
  try:
    hdecodeAll(payload, dh, ds)
  except HpackError as err:
    debugInfo err.msg
    raise newConnError(errCompressionError)

type
  Payload* = ref object
    s: seq[byte]
  Response* = ref object
    headers*: string
    data*: Payload

func newPayload(): Payload =
  Payload()

func newResponse*(): Response =
  Response(
    headers: "",
    data: newPayload()
  )

func text*(r: Response): string =
  result = ""
  result.add r.data.s

when defined(hyperxTest):
  type MyAsyncSocket = TestSocket
else:
  type MyAsyncSocket = AsyncSocket

type
  MsgData = object
    frm: Frame
    payload: Payload
  Stream = object
    id: StreamId
    state: StreamState
    msgs: QueueAsync[MsgData]

proc initStream(id: StreamId): Stream =
  result = Stream(
    id: id,
    state: strmIdle,
    msgs: newQueue[MsgData](1)
  )

type
  ClientContext* = ref object
    sock: MyAsyncSocket
    hostname: string
    port: Port
    isConnected: bool
    headersEnc, headersDec: DynHeaders
    streams: Table[StreamId, Stream]
    currStreamId: StreamId
    maxConcurrentStreams: int
    sendMsgs, recvMsgs: QueueAsync[MsgData]
    maxPeerStrmIdSeen: StreamId

when not defined(hyperxTest):
  proc newMySocket(): MyAsyncSocket =
    result = newAsyncSocket()
    wrapSocket(defaultSslContext(), result)

proc newClient*(hostname: string, port = Port 443): ClientContext =
  result = ClientContext(
    sock: newMySocket(),
    hostname: hostname,
    port: port,
    # XXX remove max headers limit
    headersEnc: initDynHeaders(headerTableSize),
    headersDec: initDynHeaders(headerTableSize),
    streams: initTable[StreamId, Stream](16),
    currStreamId: 1.StreamId,
    maxConcurrentStreams: 256,
    recvMsgs: newQueue[MsgData](10),
    sendMsgs: newQueue[MsgData](10),
    maxPeerStrmIdSeen: 0.StreamId
  )

func stream(client: ClientContext, sid: StreamId): var Stream =
  try:
    result = client.streams[sid]
  except KeyError:
    raise newConnError(errProtocolError)

func stream(client: ClientContext, sid: FrmSid): var Stream =
  client.stream sid.StreamId

proc close(client: ClientContext, sid: StreamId) =
  # Close stream messages queue and delete stream from
  # the client.
  # This does nothing if the stream is already close
  if sid notin client.streams:
    return
  let stream = client.streams[sid]
  if not stream.msgs.isClosed:
    stream.msgs.close()
  client.streams.del stream.id

proc doTransitionSend(s: var Stream, frm: Frame) =
  discard

const connFrmAllowed = {
  frmtSettings,
  frmtPing,
  frmtGoAway,
  frmtWindowUpdate
}

proc doTransitionRecv(s: var Stream, frm: Frame) =
  if s.id == frmsidMain.StreamId:
    check frm.typ in connFrmAllowed, newConnError(errProtocolError)
    return
  check frm.typ in frmRecvAllowed, newConnError(errProtocolError)
  if not s.state.isAllowedToRecv frm:
    if s.state == strmHalfClosedRemote:
      raise newStrmError(errStreamClosed)  # XXX this probably cannot be done here
    else:
      raise newConnError(errProtocolError)
  let event = frm.toEventRecv()
  let oldState = s.state
  s.state = s.state.toNextStateRecv event
  check s.state != strmInvalid, newConnError(errProtocolError)
  if oldState == strmIdle:
    # XXX close streams < s.id in idle state
    discard

proc write(client: ClientContext, frm: Frame, payload: Payload) {.async.} =
  # This is done in the next headers after settings ACK put
  if frm.typ == frmtHeaders and client.headersEnc.hasResized():
    # XXX avoid copy?
    var payloadTmp = newPayload()
    client.headersEnc.encodeLastResize(payloadTmp.s)
    client.headersEnc.clearLastResize()
    payloadTmp.s.add payload.s
    swap payload.s, payloadTmp.s
    frm.setPayloadLen payload.s.len.FrmPayloadLen
  await client.sendMsgs.put MsgData(frm: frm, payload: payload)

proc sendRstStream(
  client: ClientContext, frmSid: FrmSid, errCode: ErrorCode
) {.async.} =
  var payload = newPayload()
  var frm = newRstStreamFrame(
    payload.s, frmSid, errCode.int
  )
  try:
    await client.write(frm, payload)
  except Exception as err:
    debugInfo err.msg
    raise err

proc readNaked(client: ClientContext, sid: StreamId): Future[MsgData] {.async.} =
  template frm: untyped = result.frm
  template payload: untyped = result.payload
  result = await client.stream(sid).msgs.pop()
  doAssert sid == frm.sid.StreamId
  if frm.typ == frmtWindowUpdate:
    check payload.s.len > 0, newStrmError(errProtocolError)

proc read(client: ClientContext, sid: StreamId): Future[MsgData] {.async.} =
  template frm: untyped = result.frm
  template payload: untyped = result.payload
  try:
    result = await client.readNaked(sid)
  except StrmError as err:
    client.close(sid)
    # This needs to be done here, it cannot be
    # sent by the dispatcher or receiver
    # since it may block
    if client.isConnected:
      await client.sendRstStream(frm.sid, err.code)
    raise err

proc readUntilEnd(client: ClientContext, frm: Frame, payload: Payload) {.async.} =
  ## Read continuation frames until ``END_HEADERS`` flag is set
  assert frm.typ in {frmtHeaders, frmtPushPromise}
  assert frmfEndHeaders notin frm.flags
  var frm2 = newFrame()
  while frmfEndHeaders notin frm2.flags:
    let headerRln = await client.sock.recvInto(frm2.rawBytesPtr, frm2.len)
    check headerRln == frmHeaderSize, newConnClosedError()
    debugInfo $frm2
    check frm2.sid == frm.sid, newConnError(errProtocolError)
    check frm2.typ == frmtContinuation, newConnError(errProtocolError)
    check frm2.payloadLen >= 0
    if frm2.payloadLen == 0:
      continue
    let payloadOldLen = payload.s.len
    payload.s.setLen payloadOldLen+frm2.payloadLen.int
    let payloadRln = await client.sock.recvInto(
      addr payload.s[payloadOldLen], frm2.payloadLen.int
    )
    check payloadRln == frm2.payloadLen.int, newConnClosedError()

proc read(client: ClientContext, frm: Frame, payload: Payload) {.async.} =
  ## Read a frame + payload. If read frame is a ``Header`` or
  ## ``PushPromise``, read frames until ``END_HEADERS`` flag is set
  ## Frames cannot be interleaved here
  ##
  ## Unused flags MUST be ignored on receipt
  let headerRln = await client.sock.recvInto(frm.rawBytesPtr, frm.len)
  check headerRln == frmHeaderSize, newConnClosedError()
  debugInfo $frm
  var payloadLen = frm.payloadLen.int
  var paddingLen = 0
  if frmfPadded in frm.flags and frm.typ in frmPaddedTypes:
    debugInfo "Padding"
    check payloadLen >= frmPaddingSize, newConnError(errProtocolError)
    let paddingRln = await client.sock.recvInto(addr paddingLen, frmPaddingSize)
    check paddingRln == frmPaddingSize, newConnClosedError()
    paddingLen *= 8
    payloadLen -= frmPaddingSize
  # prio is deprecated so do nothing with it
  if frmfPriority in frm.flags and frm.typ == frmtHeaders:
    debugInfo "Priority"
    check payloadLen >= frmPrioritySize, newConnError(errProtocolError)
    var prio = 0'i64
    let prioRln = await client.sock.recvInto(addr prio, frmPrioritySize)
    check prioRln == frmPrioritySize, newConnClosedError()
    payloadLen -= frmPrioritySize
  # padding can be equal at this point, because we don't count frmPaddingSize
  check payloadLen >= paddingLen, newConnError(errProtocolError)
  payloadLen -= paddingLen
  check isValidSize(frm, payloadLen), newConnError(errFrameSizeError)
  if payloadLen > 0:
    payload.s.setLen payloadLen
    let payloadRln = await client.sock.recvInto(
      addr payload.s[0], payload.s.len
    )
    check payloadRln == payloadLen, newConnClosedError()
    debugInfo toString(frm, payload.s)
  if paddingLen > 0:
    payload.s.setLen payloadLen+paddingLen
    let paddingRln = await client.sock.recvInto(
      addr payload.s[payloadLen], paddingLen
    )
    check paddingRln == paddingLen, newConnClosedError()
    payload.s.setLen payloadLen
  if frmfEndHeaders notin frm.flags and frm.typ in {frmtHeaders, frmtPushPromise}:
    debugInfo "Continuation"
    await client.readUntilEnd(frm, payload)
  # XXX maybe do not do this here
  if frm.sid.StreamId in client.streams:
    client.stream(frm.sid).doTransitionRecv frm

proc openMainStream(client: ClientContext): StreamId =
  doAssert frmsidMain.StreamId notin client.streams
  result = frmsidMain.StreamId
  client.streams[result] = initStream result

proc openStream(client: ClientContext): StreamId =
  # XXX some error if max sid is reached
  # XXX error if maxStreams is reached
  result = client.currStreamId
  client.streams[result] = initStream result
  # client uses odd numbers, and server even numbers
  client.currStreamId += 2.StreamId

proc startHandshake(client: ClientContext) {.async.} =
  debugInfo "startHandshake"
  # we need to do this before sending any other frame
  await client.sock.send preface
  let sid = client.openMainStream()
  doAssert sid == frmsidMain.StreamId
  # XXX: allow sending some params
  var frm = newFrame()
  frm.setTyp frmtSettings
  frm.setSid frmsidMain
  await client.sock.send(frm.rawBytesPtr, frm.len)

proc connect(client: ClientContext) {.async.} =
  doAssert(not client.isConnected)
  client.isConnected = true
  await client.sock.connect(client.hostname, client.port)
  # Assume server supports http2
  await client.startHandshake()

proc close(client: ClientContext) =
  if not client.isConnected:
    return
  client.isConnected = false
  try:
    client.sock.close()
  except OSError as err:
    raise (ref InternalOSError)(msg: err.msg)
  finally:
    client.sendMsgs.close()
    client.recvMsgs.close()
    # XXX race con may create stream but
    #     client is closed
    for stream in values client.streams:
      stream.msgs.close()

proc sendTaskNaked(client: ClientContext) {.async.} =
  ## Send frames
  ## Meant to be asyncCheck'ed
  template frm: untyped = msg.frm
  template payload: untyped = msg.payload
  doAssert client.isConnected
  while client.isConnected:
    let msg = await client.sendMsgs.pop()
    doAssert frm.payloadLen.int == payload.s.len
    client.stream(frm.sid).doTransitionSend frm
    await client.sock.send(frm.rawBytesPtr, frm.len)
    if payload.s.len > 0:
      await client.sock.send(addr payload.s[0], payload.s.len)

proc sendTask(client: ClientContext) {.async.} =
  try:
    await client.sendTaskNaked()
  except OSError as err:
    if client.isConnected:
      raise (ref InternalOSError)(msg: err.msg)
    else:
      debugInfo "not connected"
  except QueueClosedError:
    doAssert not client.isConnected
  except Exception as err:
    debugInfo err.msg
    raise err
  finally:
    debugInfo "sendTask exited"
    client.close()

proc consumeMainStream(client: ClientContext, msg: MsgData) {.async.} =
  # XXX process settings, window updates, etc
  template frm: untyped = msg.frm
  template payload: untyped = msg.payload
  case frm.typ
  of frmtWindowUpdate:
    check payload.s.len > 0, newConnError(errProtocolError)
  of frmtSettings:
    for (setting, value) in settings(payload.s):
      # https://www.rfc-editor.org/rfc/rfc7541.html#section-4.2
      case setting
      of frmsHeaderTableSize:
        # maybe max table size should be a setting instead of 4096
        client.headersEnc.setLen min(value.int, headerTableSize)
      else:
        discard
    # XXX send ack
  else:
    discard

proc sendGoAway(client: ClientContext, errCode: ErrorCode) {.async.} =
  # do not send any debug information for security reasons
  var payload = newPayload()
  var frm = newGoAwayFrame(
    payload.s, client.maxPeerStrmIdSeen.int, errCode.int
  )
  try:
    await client.write(frm, payload)
  except Exception as err:
    debugInfo err.msg
    raise err

proc responseDispatcherNaked(client: ClientContext) {.async.} =
  ## Dispatch messages to open streams.
  ## Note decoding headers must be done in message received order,
  ## so it needs to be done here. Same for processing the main
  ## stream messages.
  template frm: untyped = msg.frm
  while client.isConnected:
    let msg = await client.recvMsgs.pop()
    debugInfo "recv data on stream " & $frm.sid.int
    if frm.sid == frmsidMain:
      # Settings need to be applied before consuming following messages
      await consumeMainStream(client, msg)
      continue
    if frm.sid.int mod 2 == 0:
      client.maxPeerStrmIdSeen = max(
        client.maxPeerStrmIdSeen.int, frm.sid.int
      ).StreamId
    if frm.typ == frmtHeaders:
      # XXX implement initDecodedBytes as seq[byte] in hpack
      var headers = initDecodedStr()
      # can raise a connError
      decode(msg.payload.s, headers, client.headersDec)
      msg.payload.s.setLen 0
      msg.payload.s.add $headers
    # Process headers even if the stream
    # does not exist
    if frm.sid.StreamId notin client.streams:
      # XXX need to reply as closed stream ?
      debugInfo "stream not found " & $frm.sid.int
      continue
    let stream = client.streams[frm.sid.StreamId]
    try:
      await stream.msgs.put msg
    except QueueClosedError:
      debugInfo "stream is closed " & $frm.sid.int

proc responseDispatcher(client: ClientContext) {.async.} =
  try:
    await client.responseDispatcherNaked()
  except ConnError as err:
    if client.isConnected:
      await client.sendGoAway(err.code)
    raise err
  except ConnectionClosedError as err:
    if client.isConnected:
      raise err
    else:
      debugInfo "not connected"
  except QueueClosedError:
    doAssert not client.isConnected
  except Exception as err:
    debugInfo err.msg
    raise err
  finally:
    debugInfo "responseDispatcher exited"
    client.close()

proc recvTaskNaked(client: ClientContext) {.async.} =
  ## Receive frames and dispatch to opened streams
  ## Meant to be asyncCheck'ed
  doAssert client.isConnected
  while client.isConnected:
    var frm = newFrame()
    var payload = newPayload()  # XXX remove
    await client.read(frm, payload)
    await client.recvMsgs.put MsgData(
      frm: frm,
      payload: payload
    )

proc recvTask(client: ClientContext) {.async.} =
  try:
    await client.recvTaskNaked()
  except ConnError as err:
    if client.isConnected:
      await client.sendGoAway(err.code)
    raise err
  except OSError as err:
    if client.isConnected:
      raise (ref InternalOSError)(msg: err.msg)
    else:
      debugInfo "not connected"
  except ConnectionClosedError as err:
    if client.isConnected:
      raise err
    else:
      debugInfo "not connected"
  except QueueClosedError:
    doAssert not client.isConnected
  except Exception as err:
    debugInfo err.msg
    raise err
  finally:
    debugInfo "recvTask exited"
    client.close()

template withConnection*(
  client: ClientContext,
  body: untyped
) =
  block:
    var sendFut, recvFut, respFut: Future[void]
    var waitForSendFut = false
    var waitForRecvFut = false
    var waitForRespFut = false
    try:
      debugInfo "connecting"
      await client.connect()
      debugInfo "connected"
      sendFut = client.sendTask()
      waitForSendFut = true
      recvFut = client.recvTask()
      waitForRecvFut = true
      respFut = client.responseDispatcher()
      waitForRespFut = true
      block:
        body
    except QueueClosedError:
      doAssert not client.isConnected
    except Exception as err:
      debugInfo err.msg
      raise err
    finally:
      debugInfo "exit"
      client.close()
      # XXX do gracefull shutdown with timeout,
      #     wait for send/recv to drain the queue
      #     before closing
      # XXX wait both even if one errors out
      if waitForSendFut:
        await sendFut
      if waitForRecvFut:
        await recvFut
      if waitForRespFut:
        await respFut

type
  Request* = ref object
    data: seq[byte]

func newRequest(): Request =
  Request()

func addHeader(client: ClientContext, r: Request, n, v: string) =
  ## headers must be added synchronously, no await in between,
  ## or else a table resize could occur in the meantime
  discard hencode(n, v, client.headersEnc, r.data, huffman = false)

proc request(client: ClientContext, req: Request): Future[Response] {.async.} =
  if not client.isConnected:
    raise newConnClosedError()
  result = newResponse()
  let sid = client.openStream()
  defer: client.close(sid)
  doAssert sid.FrmSid != frmsidMain
  var frm = newFrame()
  frm.setTyp frmtHeaders
  frm.setSid sid.FrmSid
  frm.flags.incl frmfEndHeaders
  var payload = newPayload()
  payload.s.add req.data
  frm.setPayloadLen payload.s.len.FrmPayloadLen
  await client.write(frm, payload)
  # XXX read in loop, discard other frames
  let msg = await client.read(sid)
  doAssert msg.frm.typ == frmtHeaders
  result.headers.add msg.payload.s
  let msg2 = await client.read(sid)
  doAssert msg2.frm.typ == frmtData
  result.data = msg2.payload

proc get*(
  client: ClientContext,
  path: string
): Future[Response] {.async.} =
  var req = newRequest()
  client.addHeader(req, ":method", "GET")
  client.addHeader(req, ":scheme", "https")
  client.addHeader(req, ":path", path)
  client.addHeader(req, ":authority", client.hostname)
  debugInfo "REQUEST"
  result = await client.request req

when defined(hyperxTest):
  proc putTestData*(client: ClientContext, data: string) {.async.} =
    await client.sock.data.put data

  proc testDataSent*(client: ClientContext): seq[byte] =
    result = client.sock.sent

when isMainModule:
  when not defined(hyperxTest):
    {.error: "tests need -d:hyperxTest".}

  block sock_default_state:
    var client = newClient("example.com")
    doAssert not client.sock.isConnected
    doAssert client.sock.hostname == ""
    doAssert client.sock.port == Port 0
  block sock_state:
    proc test() {.async.} =
      var client = newClient("example.com")
      withConnection client:
        doAssert client.sock.isConnected
        doAssert client.sock.hostname == "example.com"
        doAssert client.sock.port == Port 443
      doAssert not client.sock.isConnected
    waitFor test()

  echo "ok"
