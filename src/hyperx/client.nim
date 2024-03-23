## HTTP/2 client
## WIP

{.define: ssl.}

import ./frame
import ./stream
import ./queue
import ./errors

when defined(hyperxTest):
  import ./testsocket

const
  preface = "PRI * HTTP/2.0\r\L\r\LSM\r\L\r\L"
  statusLineLen = ":status: xxx\r\n".len
  # https://httpwg.org/specs/rfc9113.html#SettingValues
  stgHeaderTableSize = 4096'u32
  stgMaxConcurrentStreams = uint32.high
  stgInitialWindowSize = (1'u32 shl 16) - 1'u32
  stgMaxWindowSize = (1'u32 shl 31) - 1'u32
  stgInitialMaxFrameSize = 1'u32 shl 14
  stgMaxFrameSize = (1'u32 shl 24) - 1'u32
  stgDisablePush = 0'u32

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

func add(s: var seq[byte], ss: string) {.raises: [].} =
  # XXX x_x
  for c in ss:
    s.add c.byte

func add(s: var string, ss: openArray[byte]) {.raises: [].} =
  # XXX x_x
  for c in ss:
    s.add c.char

type
  StreamId = distinct uint32  # range[0 .. 31.ones.int]

proc `==`(a, b: StreamId): bool {.borrow.}
proc `+=`(a: var StreamId, b: StreamId) {.borrow.}

from std/openssl import SSL_CTX_set_alpn_protos
import std/tables
import std/net
import std/asyncdispatch
import std/asyncnet
import pkg/hpack

var sslContext {.threadvar.}: SslContext

proc destroySslContext() {.noconv.} =
  sslContext.destroyContext()

proc defaultSslContext(): SslContext {.raises: [InternalSslError].} =
  if not sslContext.isNil:
    return sslContext
  # protSSLv23 will disable all protocols
  # lower than the min protocol defined
  # in openssl.config, usually +TLSv1.2
  try:
    sslContext = newContext(protSSLv23, verifyMode=CVerifyNone)
  except CatchableError as err:
    raise newException(InternalSslError, err.msg)
  except Defect as err:
    raise err  # raise original error
  except Exception as err:
    # workaround for newContext raising Exception
    raise newException(Defect, err.msg)
  doAssert sslContext != nil, "failure to initialize the SSL context"
  # XXX OPENSSL_VERSION_NUMBER >= 0x10002000L
  discard SSL_CTX_set_alpn_protos(sslContext.context, "\x02h2", 3)
  # XXX catch EOutOfIndex
  addQuitProc(destroySslContext)
  return sslContext

func decode(
  payload: openArray[byte],
  ds: var DecodedStr,
  dh: var DynHeaders
) {.raises: [ConnError].} =
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

func newPayload(): Payload {.raises: [].} =
  Payload()

func newResponse*(): Response {.raises: [].} =
  Response(
    headers: "",
    data: newPayload()
  )

func text*(r: Response): string {.raises: [].} =
  result = ""
  result.add r.data.s

when defined(hyperxTest):
  type MyAsyncSocket = TestSocket
else:
  type MyAsyncSocket = AsyncSocket

type
  MsgData = object
    frm: Frame
  Stream = object
    # XXX: add body stream, if set stream data through it
    id: StreamId
    state: StreamState
    msgs: QueueAsync[MsgData]

proc initStream(id: StreamId): Stream {.raises: [].} =
  result = Stream(
    id: id,
    state: strmIdle,
    msgs: newQueue[MsgData](1)
  )

type
  StreamsClosedError* = object of HyperxError
  Streams = object
    t: Table[StreamId, Stream]
    isClosed: bool

func initStreams(): Streams {.raises: [].} =
  result = Streams(
    t: initTable[StreamId, Stream](16),
    isClosed: false
  )

func get(s: var Streams, sid: StreamId): var Stream {.raises: [].} =
  try:
    result = s.t[sid]
  except KeyError:
    doAssert false, "sid is not a stream"

func del(s: var Streams, sid: StreamId) {.raises: [].} =
  s.t.del sid

func contains(s: Streams, sid: StreamId): bool {.raises: [].} =
  s.t.contains sid

func open(s: var Streams, sid: StreamId) {.raises: [StreamsClosedError].} =
  doAssert sid notin s.t
  if s.isClosed:
    raise newException(StreamsClosedError, "Streams is closed")
  s.t[sid] = initStream(sid)

iterator values(s: Streams): Stream {.inline.} =
  for v in values s.t:
    yield v

proc close(s: var Streams, sid: StreamId) {.raises: [].} =
  if sid notin s:
    return
  let stream = s.get sid
  stream.msgs.close()
  s.del sid

proc close(s: var Streams) {.raises: [].} =
  if s.isClosed:
    return
  s.isClosed = true
  for stream in values s:
    stream.msgs.close()

type
  ClientContext* = ref object
    sock: MyAsyncSocket
    hostname: string
    port: Port
    isConnected: bool
    headersEnc, headersDec: DynHeaders
    streams: Streams
    currStreamId: StreamId
    sendMsgs, recvMsgs: QueueAsync[MsgData]
    maxPeerStrmIdSeen: StreamId
    peerMaxConcurrentStreams: uint32
    peerWindowSize: uint32
    peerMaxFrameSize: uint32
    exitError: ref HyperxError

when not defined(hyperxTest):
  proc newMySocket(): MyAsyncSocket {.raises: [InternalOsError].} =
    try:
      result = newAsyncSocket()
      wrapSocket(defaultSslContext(), result)
    except CatchableError as err:
      raise newInternalOsError(err.msg)

proc newClient*(
  hostname: string,
  port = Port 443
): ClientContext {.raises: [InternalOsError].} =
  result = ClientContext(
    sock: newMySocket(),
    hostname: hostname,
    port: port,
    headersEnc: initDynHeaders(stgHeaderTableSize.int),
    headersDec: initDynHeaders(stgHeaderTableSize.int),
    streams: initStreams(),
    currStreamId: 1.StreamId,
    recvMsgs: newQueue[MsgData](10),
    sendMsgs: newQueue[MsgData](10),
    maxPeerStrmIdSeen: 0.StreamId,
    peerMaxConcurrentStreams: stgMaxConcurrentStreams,
    peerWindowSize: stgInitialWindowSize,
    peerMaxFrameSize: stgInitialMaxFrameSize
  )

proc close(client: ClientContext) {.raises: [InternalOsError].} =
  if not client.isConnected:
    return
  client.isConnected = false
  try:
    client.sock.close()
  except CatchableError as err:
    raise newInternalOsError(err.msg)
  except Defect as err:
    raise err  # raise original error
  except Exception as err:
    raise newException(Defect, err.msg)
  finally:
    client.sendMsgs.close()
    client.recvMsgs.close()
    client.streams.close()

func stream(client: ClientContext, sid: StreamId): var Stream {.raises: [].} =
  client.streams.get sid

func stream(client: ClientContext, sid: FrmSid): var Stream {.raises: [].} =
  client.stream sid.StreamId

proc close(client: ClientContext, sid: StreamId) {.raises: [].} =
  # Close stream messages queue and delete stream from
  # the client.
  # This does nothing if the stream is already close
  client.streams.close sid

func doTransitionSend(s: var Stream, frm: Frame) {.raises: [].} =
  doAssert frm.sid.StreamId == s.id
  doAssert frm.sid != frmSidMain
  doAssert s.state != strmInvalid
  if frm.typ == frmtContinuation:
    return
  doAssert frm.typ in frmStreamAllowed
  s.state = toNextStateSend(s.state, frm.toStreamEvent)
  doAssert s.state != strmInvalid

# XXX continuations need a mechanism
#     similar to streamBody i.e: if frm without end is
#     found consume from streamContinuations
proc write(client: ClientContext, frm: Frame) {.async.} =
  ## Frames passed cannot be reused because they are references
  ## added to a queue, and may not have been consumed yet
  # This is done in the next headers after settings ACK put
  if frm.typ == frmtHeaders and client.headersEnc.hasResized():
    # XXX avoid copy?
    var payload = newSeq[byte]()
    client.headersEnc.encodeLastResize(payload)
    client.headersEnc.clearLastResize()
    payload.add frm.payload
    frm.shrink frm.payload.len
    frm.add payload
  if frm.sid != frmSidMain:
    client.stream(frm.sid).doTransitionSend frm
  await client.sendMsgs.put MsgData(frm: frm)

func doTransitionRecv(s: var Stream, frm: Frame) {.raises: [ConnError, StrmError].} =
  doAssert frm.sid.StreamId == s.id
  doAssert frm.sid != frmSidMain
  doAssert s.state != strmInvalid
  check frm.typ in frmStreamAllowed, newConnError(errProtocolError)
  let nextState = toNextStateRecv(s.state, frm.toStreamEvent)
  if nextState == strmInvalid:
    if s.state == strmHalfClosedRemote:
      raise newStrmError(errStreamClosed)
    else:
      raise newConnError(errProtocolError)
  s.state = nextState
  #if oldState == strmIdle:
  #  # XXX do this elsewhere not here
  #  # XXX close streams < s.id in idle state
  #  discard

proc readNaked(client: ClientContext, sid: StreamId): Future[MsgData] {.async.} =
  template frm: untyped = result.frm
  result = await client.stream(sid).msgs.pop()
  doAssert sid == frm.sid.StreamId
  # this may throw a conn error
  client.stream(sid).doTransitionRecv frm
  if frm.typ == frmtWindowUpdate:
    check frm.payload.len > 0, newStrmError(errProtocolError)
  if frm.typ == frmtData and
      frm.payloadLen.int > 0 and
      frmfEndStream notin frm.flags:
    await client.write newWindowUpdateFrame(sid.FrmSid, frm.payloadLen.int)

proc read(client: ClientContext, sid: StreamId): Future[MsgData] {.async.} =
  try:
    result = await client.readNaked(sid)
  except QueueClosedError as err:
    doAssert not client.isConnected
    if client.exitError != nil:
      raise newHyperxConnectionError(client.exitError.msg)
    raise err
  except StrmError as err:
    #client.close(sid)
    if client.isConnected:
      await client.write newRstStreamFrame(sid.FrmSid, err.code.int)
    raise err
  except ConnError as err:
    debugInfo err.msg
    client.close()
    raise err

proc readUntilEnd(client: ClientContext, frm: Frame) {.async.} =
  ## Read continuation frames until ``END_HEADERS`` flag is set
  doAssert frm.typ in {frmtHeaders, frmtPushPromise}
  doAssert frmfEndHeaders notin frm.flags
  var frm2 = newFrame()
  while frmfEndHeaders notin frm2.flags:
    check not client.sock.isClosed, newConnClosedError()
    let headerRln = await client.sock.recvInto(frm2.rawBytesPtr, frm2.len)
    check headerRln == frmHeaderSize, newConnClosedError()
    debugInfo $frm2
    check frm2.sid == frm.sid, newConnError(errProtocolError)
    check frm2.typ == frmtContinuation, newConnError(errProtocolError)
    check frm2.payloadLen <= stgInitialMaxFrameSize, newConnError(errProtocolError)
    check frm2.payloadLen >= 0
    if frm2.payloadLen == 0:
      continue
    # XXX the spec does not limit total headers size,
    #     but there needs to be a limit unless we stream
    let totalPayloadLen = frm2.payloadLen.int + frm.payload.len
    check totalPayloadLen <= stgInitialMaxFrameSize.int, newConnError(errProtocolError)
    let oldFrmLen = frm.len
    frm.grow frm2.payloadLen.int
    check not client.sock.isClosed, newConnClosedError()
    let payloadRln = await client.sock.recvInto(
      addr frm.s[oldFrmLen], frm2.payloadLen.int
    )
    check payloadRln == frm2.payloadLen.int, newConnClosedError()
  frm.setPayloadLen frm.payload.len.FrmPayloadLen
  frm.flags.incl frmfEndHeaders

proc read(client: ClientContext, frm: Frame) {.async.} =
  ## Read a frame + payload. If read frame is a ``Header`` or
  ## ``PushPromise``, read frames until ``END_HEADERS`` flag is set
  ## Frames cannot be interleaved here
  ##
  ## Unused flags MUST be ignored on receipt
  check not client.sock.isClosed, newConnClosedError()
  let headerRln = await client.sock.recvInto(frm.rawBytesPtr, frm.len)
  check headerRln == frmHeaderSize, newConnClosedError()
  debugInfo $frm
  var payloadLen = frm.payloadLen.int
  check payloadLen <= stgInitialMaxFrameSize.int, newConnError(errProtocolError)
  var paddingLen = 0
  if frmfPadded in frm.flags and frm.typ in frmPaddedTypes:
    debugInfo "Padding"
    check payloadLen >= frmPaddingSize, newConnError(errProtocolError)
    check not client.sock.isClosed, newConnClosedError()
    let paddingRln = await client.sock.recvInto(addr paddingLen, frmPaddingSize)
    check paddingRln == frmPaddingSize, newConnClosedError()
    paddingLen *= 8
    payloadLen -= frmPaddingSize
  # prio is deprecated so do nothing with it
  if frmfPriority in frm.flags and frm.typ == frmtHeaders:
    debugInfo "Priority"
    check payloadLen >= frmPrioritySize, newConnError(errProtocolError)
    var prio = 0'i64
    check not client.sock.isClosed, newConnClosedError()
    let prioRln = await client.sock.recvInto(addr prio, frmPrioritySize)
    check prioRln == frmPrioritySize, newConnClosedError()
    payloadLen -= frmPrioritySize
  # padding can be equal at this point, because we don't count frmPaddingSize
  check payloadLen >= paddingLen, newConnError(errProtocolError)
  payloadLen -= paddingLen
  check isValidSize(frm, payloadLen), newConnError(errFrameSizeError)
  if payloadLen > 0:
    # XXX recv into Stream.bodyStream if typ is frmtData
    # XXX recv in chunks and discard if stream does not exists
    frm.grow payloadLen
    check not client.sock.isClosed, newConnClosedError()
    let payloadRln = await client.sock.recvInto(
      frm.rawPayloadBytesPtr, payloadLen
    )
    check payloadRln == payloadLen, newConnClosedError()
    debugInfo frm.debugPayload
  if paddingLen > 0:
    let oldFrmLen = frm.len
    frm.grow paddingLen
    check not client.sock.isClosed, newConnClosedError()
    let paddingRln = await client.sock.recvInto(
      addr frm.s[oldFrmLen], paddingLen
    )
    check paddingRln == paddingLen, newConnClosedError()
    frm.shrink paddingLen
  if frmfEndHeaders notin frm.flags and frm.typ in {frmtHeaders, frmtPushPromise}:
    debugInfo "Continuation"
    await client.readUntilEnd(frm)

func openMainStream(client: ClientContext): StreamId {.raises: [StreamsClosedError].} =
  doAssert frmSidMain.StreamId notin client.streams
  result = frmSidMain.StreamId
  client.streams.open result

func openStream(client: ClientContext): StreamId {.raises: [StreamsClosedError].} =
  # XXX some error if max sid is reached
  # XXX error if maxStreams is reached
  result = client.currStreamId
  client.streams.open result
  # client uses odd numbers, and server even numbers
  client.currStreamId += 2.StreamId

proc handshake(client: ClientContext) {.async.} =
  doAssert client.isConnected
  debugInfo "handshake"
  # we need to do this before sending any other frame
  # XXX: allow sending some params
  let sid = client.openMainStream()
  doAssert sid == frmSidMain.StreamId
  var frm = newSettingsFrame()
  frm.addSetting frmsEnablePush, stgDisablePush
  frm.addSetting frmsInitialWindowSize, stgMaxWindowSize
  var blob = newSeqOfCap[byte](preface.len+frm.len)
  blob.add preface
  blob.add frm.s
  check not client.sock.isClosed, newConnClosedError()
  await client.sock.send(addr blob[0], blob.len)

proc connect(client: ClientContext) {.async.} =
  doAssert(not client.isConnected)
  client.isConnected = true
  await client.sock.connect(client.hostname, client.port)
  # Assume server supports http2
  await client.handshake()

proc sendTaskNaked(client: ClientContext) {.async.} =
  ## Send frames
  ## Meant to be asyncCheck'ed
  template frm: untyped = msg.frm
  doAssert client.isConnected
  while client.isConnected:
    let msg = await client.sendMsgs.pop()
    doAssert frm.payloadLen.int == frm.payload.len
    doAssert frm.payload.len <= client.peerMaxFrameSize.int
    check not client.sock.isClosed, newConnClosedError()
    await client.sock.send(frm.rawBytesPtr, frm.len)

proc sendTask(client: ClientContext) {.async.} =
  try:
    await client.sendTaskNaked()
  except HyperxError as err:
    if client.isConnected:
      client.exitError = err
      raise err
    else:
      debugInfo "not connected"
  except QueueClosedError:
    doAssert not client.isConnected
  except OSError as err:  # XXX remove
    if client.isConnected:
      client.exitError = newInternalOsError(err.msg)
      raise client.exitError
    else:
      debugInfo "not connected"
  except CatchableError as err:
    debugInfo err.msg
    raise err
  finally:
    debugInfo "sendTask exited"
    client.close()

const connFrmAllowed = {
  frmtSettings,
  frmtPing,
  frmtGoAway,
  frmtWindowUpdate
}

proc consumeMainStream(client: ClientContext, frm: Frame) {.async.} =
  case frm.typ
  of frmtWindowUpdate:
    check frm.payload.len > 0, newConnError(errProtocolError)
  of frmtSettings:
    for (setting, value) in frm.settings:
      # https://www.rfc-editor.org/rfc/rfc7541.html#section-4.2
      case setting
      of frmsHeaderTableSize:
        # maybe max table size should be a setting instead of 4096
        client.headersEnc.setSize min(value.int, stgHeaderTableSize.int)
      of frmsEnablePush:
        check value == 0, newConnError(errProtocolError)
      of frmsMaxConcurrentStreams:
        client.peerMaxConcurrentStreams = value
      of frmsInitialWindowSize:
        check value <= stgMaxWindowSize, newConnError(errFlowControlError)
        # XXX update all open streams windows
        #client.peerWindowSize = value
      of frmsMaxFrameSize:
        check value >= stgInitialMaxFrameSize, newConnError(errProtocolError)
        check value <= stgMaxFrameSize, newConnError(errProtocolError)
        client.peerMaxFrameSize = value
      of frmsMaxHeaderListSize:
        # this is only advisory, do nothing for now.
        # server may reply a 431 status (request header fields too large)
        discard
      else:
        # ignore unknown setting
        debugInfo "unknown setting received"
    await client.write newSettingsFrame(ack = true)
  of frmtPing:
    if frmfAck notin frm.flags:
      await client.write newPingFrame(ackPayload = frm.payload)
  of frmtGoAway:
    # XXX close streams lower than Last-Stream-ID
    # XXX don't allow new streams creation
    # the connection is still ok for streams lower than Last-Stream-ID
    discard
  else:
    doAssert frm.typ notin connFrmAllowed
    raise newConnError(errProtocolError)

proc sendGoAway(client: ClientContext, errCode: ErrorCode) {.async.} =
  # do not send any debug information for security reasons
  var frm = newGoAwayFrame(
    client.maxPeerStrmIdSeen.int, errCode.int
  )
  try:
    await client.write(frm)
  except CatchableError as err:
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
    if frm.sid == frmSidMain:
      # Settings need to be applied before consuming following messages
      await consumeMainStream(client, frm)
      continue
    if frm.sid.int mod 2 == 0:
      client.maxPeerStrmIdSeen = max(
        client.maxPeerStrmIdSeen.int, frm.sid.int
      ).StreamId
    if frm.typ == frmtHeaders:
      # XXX implement initDecodedBytes as seq[byte] in hpack
      var headers = initDecodedStr()
      # can raise a connError
      decode(frm.payload, headers, client.headersDec)
      frm.shrink frm.payload.len
      frm.s.add $headers
    if frm.typ == frmtData and frm.payloadLen.int > 0:
      await client.write newWindowUpdateFrame(frmSidMain, frm.payloadLen.int)
    # Process headers even if the stream
    # does not exist
    if frm.sid.StreamId notin client.streams:
      # XXX need to reply as closed stream ?
      debugInfo "stream not found " & $frm.sid.int
      continue
    let stream = client.streams.get frm.sid.StreamId
    try:
      await stream.msgs.put msg
    except QueueClosedError:
      debugInfo "stream is closed " & $frm.sid.int

proc responseDispatcher(client: ClientContext) {.async.} =
  try:
    await client.responseDispatcherNaked()
  except ConnError as err:
    if client.isConnected:
      client.exitError = err
      await client.sendGoAway(err.code)
    raise err
  except HyperxError as err:
    if client.isConnected:
      client.exitError = err
      raise err
    else:
      debugInfo "not connected"
  except QueueClosedError:
    doAssert not client.isConnected
  except CatchableError as err:
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
    await client.read(frm)
    await client.recvMsgs.put MsgData(frm: frm)

proc recvTask(client: ClientContext) {.async.} =
  try:
    await client.recvTaskNaked()
  except ConnError as err:
    if client.isConnected:
      # XXX close all streams
      client.exitError = err
      await client.sendGoAway(err.code)
    raise err
  except HyperxError as err:
    if client.isConnected:
      client.exitError = err
      raise err
    else:
      debugInfo "not connected"
  except QueueClosedError:
    doAssert not client.isConnected
  except OSError as err:
    if client.isConnected:
      client.exitError = newInternalOsError(err.msg)
      raise client.exitError
    else:
      debugInfo "not connected"
  except CatchableError as err:
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
    try:
      debugInfo "connecting"
      await client.connect()
      debugInfo "connected"
      sendFut = client.sendTask()
      recvFut = client.recvTask()
      respFut = client.responseDispatcher()
      block:
        body
    except QueueClosedError as err:
      doAssert not client.isConnected
      raise err
    except CatchableError as err:
      debugInfo err.msg
      raise err
    finally:
      debugInfo "exit"
      client.close()
      # XXX do gracefull shutdown with timeout,
      #     wait for send/recv to drain the queue
      #     before closing
      
      # do not bother the user with hyperx errors
      # at this point body completed or errored out
      for fut in [sendFut, recvFut, respFut]:
        try:
          if fut != nil:
            await fut
        except HyperxError as err:
          debugInfo err.msg

type
  Request = object
    headersFrm: Frame
    dataFrm: Frame

func newRequest(): Request {.raises: [].} =
  Request(
    headersFrm: newFrame(),
    dataFrm: newEmptyFrame()
  )

func addHeader(client: ClientContext, r: Request, n, v: string) {.raises: [HyperxError].} =
  ## headers must be added synchronously, no await in between,
  ## or else a table resize could occur in the meantime
  try:
    discard hencode(n, v, client.headersEnc, r.headersFrm.s, huffman = false)
  except HpackError as err:
    raise newException(HyperxError, err.msg)

# XXX remove
proc request(client: ClientContext, req: Request): Future[Response] {.async.} =
  debugInfo "request"
  if not client.isConnected:
    raise newConnClosedError()
  result = newResponse()
  let sid = client.openStream()
  defer: client.close(sid)
  doAssert sid.FrmSid != frmSidMain
  req.headersFrm.setTyp frmtHeaders
  req.headersFrm.setSid sid.FrmSid
  req.headersFrm.setPayloadLen req.headersFrm.payloadSize.FrmPayloadLen
  req.headersFrm.flags.incl frmfEndHeaders
  if req.dataFrm.isEmpty:
    req.headersFrm.flags.incl frmfEndStream
  await client.write req.headersFrm
  if not req.dataFrm.isEmpty:
    req.dataFrm.setTyp frmtData
    req.dataFrm.setSid sid.FrmSid
    req.dataFrm.setPayloadLen req.dataFrm.payloadSize.FrmPayloadLen
    req.dataFrm.flags.incl frmfEndStream
    await client.write req.dataFrm
  # https://httpwg.org/specs/rfc9113.html#HttpFraming
  while true:
    let msg = await client.read(sid)
    check msg.frm.typ == frmtHeaders, newStrmError(errProtocolError)
    check msg.frm.payload.len >= statusLineLen, newStrmError(errProtocolError)
    #check msg.frm.payload.startsWith ":status: ", newStrmError(errProtocolError)
    if msg.frm.payload[9] == '1'.byte:
      check frmfEndStream notin msg.frm.flags, newStrmError(errProtocolError)
    else:
      result.headers.add msg.frm.payload
      if frmfEndStream in msg.frm.flags:
        return
      break
  while true:
    let msg = await client.read(sid)
    # XXX store trailer headers
    # https://www.rfc-editor.org/rfc/rfc9110.html#section-6.5
    if msg.frm.typ == frmtHeaders:
      check frmfEndStream in msg.frm.flags, newStrmError(errProtocolError)
      return
    check msg.frm.typ == frmtData, newStrmError(errProtocolError)
    result.data.s.add msg.frm.payload
    if frmfEndStream in msg.frm.flags:
      return

type
  HttpMethod* = enum
    hmPost, hmGet, hmPut, hmHead, hmOptions, hmDelete, hmPatch

func `$`(hm: HttpMethod): string =
  case hm
  of hmPost: "POST"
  of hmGet: "GET"
  of hmPut: "PUT"
  of hmHead: "HEAD"
  of hmOptions: "OPTIONS"
  of hmDelete: "DELETE"
  of hmPatch: "PATCH"

const
  defaultUserAgent = "Nim - HyperX"
  defaultAccept = "*/*"
  defaultContentType = "application/json"

# XXX remove
proc request(
  client: ClientContext,
  httpMethod: HttpMethod,
  path: string,
  data: seq[byte] = @[],
  userAgent = defaultUserAgent,
  accept = defaultAccept,
  contentType = defaultContentType
): Future[Response] {.async.} =
  # XXX move to its own func and call from request
  #     no await calls in between
  var req = newRequest()
  client.addHeader(req, ":method", $httpMethod)
  client.addHeader(req, ":scheme", "https")
  client.addHeader(req, ":path", path)
  client.addHeader(req, ":authority", client.hostname)
  # host is deprecated in http2 and some servers return a protocol error
  # client.addHeader(req, "host", client.hostname)
  client.addHeader(req, "user-agent", userAgent)
  if httpMethod in {hmGet, hmHead}:
    client.addHeader(req, "accept", accept)
  if httpMethod in {hmPost, hmPut, hmPatch}:
    client.addHeader(req, "content-type", contentType)
    client.addHeader(req, "content-length", $data.len)
    req.dataFrm = newFrame()
    req.dataFrm.add data
  result = await client.request req

proc get*(
  client: ClientContext,
  path: string,
  accept = defaultAccept
): Future[Response] {.async.} =
  result = await request(client, hmGet, path, accept = accept)

proc head*(
  client: ClientContext,
  path: string,
  accept = defaultAccept
): Future[Response] {.async.} =
  result = await request(client, hmHead, path, accept = accept)

proc post*(
  client: ClientContext,
  path: string,
  data: seq[byte],
  contentType = defaultContentType
): Future[Response] {.async.} =
  # https://httpwg.org/specs/rfc9113.html#n-complex-request
  result = await request(
    client, hmPost, path, data = data, contentType = contentType
  )

proc put*(
  client: ClientContext,
  path: string,
  data: seq[byte],
  contentType = defaultContentType
): Future[Response] {.async.} =
  result = await request(
    client, hmPut, path, data = data, contentType = contentType
  )

proc delete*(
  client: ClientContext,
  path: string
): Future[Response] {.async.} =
  result = await request(client, hmDelete, path)

type
  ClientStreamState = enum
    csStateInitial,
    csStateOpened,
    csStateSentHeaders,
    csStateSentData,
    csStateSentEnded,
    csStateRecvHeaders,
    csStateRecvData,
    csStateRecvEnded
  ClientStream* = ref object
    client: ClientContext
    sid: StreamId
    state: ClientStreamState

func newClientStream*(client: ClientContext): ClientStream =
  ClientStream(
    client: client,
    sid: client.openStream(),
    state: csStateInitial
  )

proc close(strm: ClientStream) =
  strm.client.close(strm.sid)

func ended*(strm: ClientStream): bool =
  strm.state == csStateRecvEnded

func addHeader(
  client: ClientContext,
  frm: Frame,
  n, v: string
) {.raises: [HyperxError].} =
  ## headers must be added synchronously, no await in between,
  ## or else a table resize could occur in the meantime
  try:
    discard hencode(n, v, client.headersEnc, frm.s, huffman = false)
  except HpackError as err:
    raise newException(HyperxError, err.msg)

proc sendHeaders*(
  strm: ClientStream,
  httpMethod: HttpMethod,
  path: string,
  userAgent = defaultUserAgent,
  accept = defaultAccept,
  contentType = defaultContentType,
  contentLen = 0
) {.async.} =
  template client: untyped = strm.client
  doAssert strm.state == csStateOpened
  strm.state = csStateSentHeaders
  #if not client.isConnected:
  #  raise newConnClosedError()
  var frm = newFrame()
  client.addHeader(frm, ":method", $httpMethod)
  client.addHeader(frm, ":scheme", "https")
  client.addHeader(frm, ":path", path)
  client.addHeader(frm, ":authority", client.hostname)
  client.addHeader(frm, "user-agent", userAgent)
  client.addHeader(frm, "accept", accept)
  if httpMethod in {hmGet, hmHead}:
    client.addHeader(frm, "accept", accept)
  if httpMethod in {hmPost, hmPut, hmPatch}:
    client.addHeader(frm, "content-type", contentType)
    client.addHeader(frm, "content-length", $contentLen)
  frm.setTyp frmtHeaders
  frm.setSid strm.sid.FrmSid
  frm.setPayloadLen frm.payloadSize.FrmPayloadLen
  frm.flags.incl frmfEndHeaders
  if contentLen == 0:
    frm.flags.incl frmfEndStream
    strm.state = csStateSentEnded
  await client.write frm

proc sendBody*(
  strm: ClientStream,
  data: ref string,
  finish = false
) {.async.} =
  doAssert strm.state in {csStateSentHeaders, csStateSentData}
  strm.state = csStateSentData
  var frm = newFrame()
  frm.setTyp frmtData
  frm.setSid strm.sid.FrmSid
  frm.setPayloadLen data[].len.FrmPayloadLen
  if finish:
    frm.flags.incl frmfEndStream
    strm.state = csStateSentEnded
  frm.s.add data[]
  await strm.client.write frm

proc recvHeaders*(strm: ClientStream, data: ref string) {.async.} =
  doAssert strm.state == csStateSentEnded
  strm.state = csStateRecvHeaders
  # https://httpwg.org/specs/rfc9113.html#HttpFraming
  var msg: MsgData
  while true:
    msg = await strm.client.read(strm.sid)
    check msg.frm.typ == frmtHeaders, newStrmError(errProtocolError)
    check msg.frm.payload.len >= statusLineLen, newStrmError(errProtocolError)
    #check msg.frm.payload.startsWith ":status: ", newStrmError(errProtocolError)
    if msg.frm.payload[9] == '1'.byte:
      check frmfEndStream notin msg.frm.flags, newStrmError(errProtocolError)
    else:
      break
  data[].add msg.frm.payload
  if frmfEndStream in msg.frm.flags:
    strm.state = csStateRecvEnded

proc recvBody*(strm: ClientStream, data: ref string) {.async.} =
  doAssert strm.state in {csStateRecvHeaders, csStateRecvData}
  strm.state = csStateRecvData
  let msg = await strm.client.read(strm.sid)
  # XXX store trailer headers
  # https://www.rfc-editor.org/rfc/rfc9110.html#section-6.5
  if msg.frm.typ == frmtHeaders:
    check frmfEndStream in msg.frm.flags, newStrmError(errProtocolError)
    strm.state = csStateRecvEnded
    return
  check msg.frm.typ == frmtData, newStrmError(errProtocolError)
  data[].add msg.frm.payload
  if frmfEndStream in msg.frm.flags:
    strm.state = csStateRecvEnded

template withStream*(strm: ClientStream, body: untyped): untyped =
  doAssert strm.state == csStateInitial
  strm.state = csStateOpened
  try:
    block:
      body
    doAssert strm.state == csStateRecvEnded
  finally:
    strm.close()

when defined(hyperxTest):
  proc putRecvTestData*(client: ClientContext, data: seq[byte]) {.async.} =
    await client.sock.putRecvData data

  proc sentTestData*(client: ClientContext, size: int): Future[seq[byte]] {.async.}  =
    result = newSeq[byte](size)
    let sz = await client.sock.sentInto(addr result[0], size)
    result.setLen sz

when isMainModule:
  when not defined(hyperxTest):
    {.error: "tests need -d:hyperxTest".}

  block default_settins:
    doAssert stgHeaderTableSize == 4096'u32
    doAssert stgMaxConcurrentStreams == uint32.high
    doAssert stgInitialWindowSize == 65_535'u32
    doAssert stgMaxWindowSize == 2_147_483_647'u32
    doAssert stgInitialMaxFrameSize == 16_384'u32
    doAssert stgMaxFrameSize == 16_777_215'u32
    doAssert stgDisablePush == 0'u32
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
