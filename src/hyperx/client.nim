## HTTP/2 client
## WIP

{.define: ssl.}

import pkg/hpack/decoder
import ./frame
import ./stream
import ./queue
import ./lock

when defined(hyperxTest):
  import ./testsocket

# https://httpwg.org/specs/rfc9113.html#ErrorCodes
type
  ErrorCode = distinct uint8
const
  errNoError = 0x00.ErrorCode
  errProtocolError = 0x01.ErrorCode
  errInternalError = 0x02.ErrorCode
  errFlowControlError = 0x03.ErrorCode
  errSettingsTimeout = 0x04.ErrorCode
  errStreamClosed = 0x05.ErrorCode
  errFrameSizeError = 0x06.ErrorCode
  errRefusedStream = 0x07.ErrorCode
  errCancel = 0x08.ErrorCode
  errCompressionError = 0x09.ErrorCode
  errConnectError = 0x0a.ErrorCode
  errEnhanceYourCalm = 0x0b.ErrorCode
  errInadequateSecurity = 0x0c.ErrorCode
  errHttp11Required = 0x0d.ErrorCode

func `$`(errCode: ErrorCode): string =
  case errCode
  of errNoError: "NO_ERROR"
  of errProtocolError: "PROTOCOL_ERROR"
  of errInternalError: "INTERNAL_ERROR"
  of errFlowControlError: "FLOW_CONTROL_ERROR"
  of errSettingsTimeout: "SETTINGS_TIMEOUT"
  of errStreamClosed: "STREAM_CLOSED"
  of errFrameSizeError: "FRAME_SIZE_ERROR"
  of errRefusedStream: "REFUSED_STREAM"
  of errCancel: "CANCEL"
  of errCompressionError: "COMPRESSION_ERROR"
  of errConnectError: "CONNECT_ERROR"
  of errEnhanceYourCalm: "ENHANCE_YOUR_CALM"
  of errInadequateSecurity: "INADEQUATE_SECURITY"
  of errHttp11Required: "HTTP_1_1_REQUIRED"
  else: "UNKNOWN ERROR CODE"

type
  HyperxError* = object of CatchableError
  HyperxConnectionError* = object of HyperxError
  ConnError = object of HyperxConnectionError
    code: ErrorCode
  ConnectionClosedError = object of HyperxConnectionError
  InternalOSError = object of HyperxConnectionError
  StrmError = object of HyperxError
  StrmProtocolError = object of StrmError
  StrmStreamClosedError = object of StrmError

func newConnError(errCode: ErrorCode): ref ConnError =
  result = (ref ConnError)(code: errCode, msg: "Connection Error: " & $errCode)

func newConnClosedError(): ref ConnectionClosedError =
  result = (ref ConnectionClosedError)()

const
  preface = "PRI * HTTP/2.0\r\L\r\LSM\r\L\r\L"
  # https://httpwg.org/specs/rfc9113.html#SettingValues
  headerTableSize = 4096

template debugInfo(s: string): untyped =
  when defined(hyperxDebug):
    debugEcho s
  else:
    discard

template raiseError(err, msg) =
  raise (ref err)(msg: msg)

template raiseError(err) =
  raise (ref err)()

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
  StrmMsgData = object
    frmTyp: FrmTyp
    payload: Payload
  Response* = ref object
    headers*: string
    data*: Payload

func newPayload(): Payload =
  Payload()

func initStrmMsgData(frmTyp: FrmTyp): StrmMsgData =
  StrmMsgData(
    frmTyp: frmTyp,
    payload: newPayload()
  )

func newResponse*(): Response =
  Response(
    headers: "",
    data: newPayload()
  )

func text*(r: Response): string =
  result = ""
  result.add r.data.s

type
  Stream = object
    id: StreamId
    state: StreamState
    strmMsgs: QueueAsync[StrmMsgData]

proc read(s: Stream): Future[StrmMsgData] {.async.} =
  result = await s.strmMsgs.pop()

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
      raiseError StrmStreamClosedError
    else:
      raise newConnError(errProtocolError)
  let event = frm.toEventRecv()
  let oldState = s.state
  s.state = s.state.toNextStateRecv event
  check s.state != strmInvalid, newConnError(errProtocolError)
  if oldState == strmIdle:
    # XXX close streams < s.id in idle state
    discard

when defined(hyperxTest):
  type MyAsyncSocket = TestSocket
else:
  type MyAsyncSocket = AsyncSocket

type
  DptMsgData = object
    strmId: StreamId
    frmTyp: FrmTyp
    payload: Payload
  ClientContext* = ref object
    sock: MyAsyncSocket
    hostname: string
    port: Port
    isConnected: bool
    dynEncHeaders, dynDecHeaders: DynHeaders
    streams: Table[StreamId, Stream]
    currStreamId: StreamId
    maxConcurrentStreams: int
    dptMsgs: QueueAsync[DptMsgData]
    writeLock: LockAsync
    maxPeerStreamIdSeen: StreamId

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
    dynEncHeaders: initDynHeaders(headerTableSize, 16),
    dynDecHeaders: initDynHeaders(headerTableSize, 16),
    streams: initTable[StreamId, Stream](16),
    currStreamId: 1.StreamId,
    maxConcurrentStreams: 256,
    dptMsgs: newQueue[DptMsgData](10),
    writeLock: newLock(),
    maxPeerStreamIdSeen: 0.StreamId
  )

proc initStream(id: StreamId): Stream =
  result = Stream(
    id: id,
    state: strmIdle,
    strmMsgs: newQueue[StrmMsgData](1)
  )

func stream(client: ClientContext, sid: StreamId): var Stream =
  try:
    result = client.streams[sid]
  except KeyError:
    raise newConnError(errProtocolError)

func stream(client: ClientContext, sid: FrmSid): var Stream =
  client.stream sid.StreamId

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
  case frm.typ
  of frmtHeaders, frmtPushPromise:
    if frmfEndHeaders notin frm.flags:
      debugInfo "Continuation"
      await client.readUntilEnd(frm, payload)
  else:
    discard
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

# XXX writing should be a task + queue like read
proc write(client: ClientContext, frm: Frame) {.async.} =
  client.stream(frm.sid).doTransitionSend frm
  withLock(client.writeLock):
    await client.sock.send(frm.rawBytesPtr, frm.len)

proc write(client: ClientContext, frm: Frame, payload: Payload) {.async.} =
  doAssert frm.payloadLen.int == payload.s.len
  client.stream(frm.sid).doTransitionSend frm
  withLock(client.writeLock):
    await client.sock.send(frm.rawBytesPtr, frm.len)
    if payload.s.len > 0:
      await client.sock.send(addr payload.s[0], payload.s.len)

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
  await client.write frm

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
    client.dptMsgs.close()
    # XXX race con may create stream but
    #     client is closed
    for stream in values client.streams:
      stream.strmMsgs.close()

proc consumeMainStream(client: ClientContext, dptMsg: DptMsgData) {.async.} =
  # XXX process settings, window updates, etc
  discard

proc sendGoAway(client: ClientContext, errCode: ErrorCode) {.async.} =
  # do not send any debug information for security reasons
  var payload = newPayload()
  var frm = newGoAwayFrame(
    payload.s, client.maxPeerStreamIdSeen.int, errCode.int
  )
  try:
    await client.write(frm, payload)
  except Exception as err:
    debugInfo err.msg
    raise err

proc responseDispatcherNaked(client: ClientContext) {.async.} =
  ## Dispatch messages to open streams. Note decoding
  ## headers must be done in message received order, so
  ## it needs to be done here. Same for processing the main
  ## stream messages.
  while client.isConnected:
    let dptMsg = await client.dptMsgs.pop()
    if dptMsg.strmId notin client.streams:
      debugInfo "stream not found " & $dptMsg.strmId.int
      continue
    debugInfo "recv data on stream " & $dptMsg.strmId.int
    if dptMsg.strmId == frmsidMain.StreamId:
      await consumeMainStream(client, dptMsg)
      continue
    if dptMsg.strmId.int mod 2 == 0:
      client.maxPeerStreamIdSeen = max(
        client.maxPeerStreamIdSeen.int, dptMsg.strmId.int
      ).StreamId
    let stream = client.streams[dptMsg.strmId]
    var strmMsg = initStrmMsgData(dptMsg.frmTyp)
    if dptMsg.frmTyp == frmtHeaders:
      # XXX implement initDecodedBytes as seq[byte] in hpack
      var headers = initDecodedStr()
      # can raise a connError
      decode(dptMsg.payload.s, headers, client.dynDecHeaders)
      strmMsg.payload.s.add $headers
    else:
      strmMsg.payload = dptMsg.payload
    await stream.strmMsgs.put strmMsg

proc responseDispatcher(client: ClientContext) {.async.} =
  try:
    await client.responseDispatcherNaked()
  except ConnError as err:
    if client.isConnected:
      await client.sendGoAway(err.code)
    raise err
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
  var frm = newFrame()
  while client.isConnected:
    frm.clear()
    var payload = newPayload()  # XXX remove
    await client.read(frm, payload)
    await client.dptMsgs.put DptMsgData(
      strmId: frm.sid.StreamId,
      frmTyp: frm.typ,
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
    var recvFut: Future[void]
    var waitForRecvFut = false
    var respFut: Future[void]
    var waitForRespFut = false
    try:
      debugInfo "connecting"
      await client.connect()
      debugInfo "connected"
      recvFut = client.recvTask()
      waitForRecvFut = true
      respFut = client.responseDispatcher()
      waitForRespFut = true
      block:
        body
    except Exception as err:
      debugInfo err.msg
      raise err
    finally:
      debugInfo "exit"
      client.close()
      try:
        if waitForRecvFut:
          await recvFut
      except ConnectionClosedError, QueueClosedError:
        discard
      try:
        if waitForRespFut:
          await respFut
      except ConnectionClosedError, QueueClosedError:
        discard

type
  Request* = ref object
    data: seq[byte]

func newRequest(): Request =
  Request()

func addHeader(client: ClientContext, r: Request, n, v: string) =
  discard hencode(n, v, client.dynEncHeaders, r.data, huffman = false)

proc request(client: ClientContext, req: Request): Future[Response] {.async.} =
  result = newResponse()
  let sid = client.openStream()
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
  let strmMsg = await client.stream(sid).read()
  doAssert strmMsg.frmTyp == frmtHeaders
  result.headers.add strmMsg.payload.s
  let strmMsg2 = await client.stream(sid).read()
  doAssert strmMsg2.frmTyp == frmtData
  result.data = strmMsg2.payload
  client.streams.del sid  # XXX need to reply as closed stream

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
