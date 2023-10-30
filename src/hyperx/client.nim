## HTTP/2 client
## WIP

{.define: ssl.}

import pkg/hpack/decoder
import ./frame
import ./queue

type
  HyperxError* = object of CatchableError
  # XXX rename to ConnError + use prefix Conn
  ConnectionError = object of HyperxError
  ConnectionClosedError = object of HyperxError
  ProtocolError = object of ConnectionError
  StreamClosedError = object of ConnectionError
  CompressionError = object of ConnectionError
  FrameSizeError = object of HyperxError
  StrmError = object of HyperxError
  StrmProtocolError = object of StrmError
  StrmStreamClosedError = object of StrmError

const
  preface = "PRI * HTTP/2.0\r\L\r\LSM\r\L\r\L"

template debugInfo(s: string): untyped =
  when defined(hyperxDebug):
    debugEcho s
  else:
    discard

template raiseError(err, msg) =
  raise newException(err, msg)

template raiseError(err) =
  raise newException(err, "Error")

template check(cond: bool): untyped =
  if not cond:
    raiseError(HyperxError, "Error")

template check(cond: bool, errObj: untyped): untyped =
  if not cond:
    raiseError(errObj, "Error")

func add(s: var seq[byte], ss: string) =
  # XXX x_x
  for c in ss:
    s.add c.byte

# Section 5.1
type
  StreamState = enum
    strmIdle
    strmOpen
    strmClosed
    strmReservedLocal
    strmReservedRemote
    strmHalfClosedLocal
    strmHalfClosedRemote
    strmInvalid
  StreamEvent = enum
    seHeadersRecv
    seHeadersSend
    sePushPromiseRecv
    sePushPromiseSend
    seEndStreamRecv
    seEndStreamSend
    seRstStream
    sePriorityRecv
    sePrioritySend
    seWindowUpdateRecv
    seWindowUpdateSend
    seDataRecv
    # seFlowControlRecv
    # seFlowControlSend
    # seSomeRecv
    # seSomeSend
    seUnknown

# XXX strmInvalid is a connection error when recv
#     and some programming error when send
# XXX ignore unknow evet
func transition(s: StreamState, e: StreamEvent): StreamState =
  case s
  of strmIdle:
    case e:
    of seHeadersRecv, seHeadersSend:
      strmOpen
    of sePushPromiseRecv: # or error?
      strmReservedRemote
    of sePushPromiseSend:
      strmReservedLocal
    of seEndStreamRecv:
      strmHalfClosedRemote
    of seEndStreamSend:
      strmHalfClosedLocal
    of sePriorityRecv:
      strmIdle
    else:
      strmInvalid
  of strmOpen:
    case e
    of seEndStreamSend:
      strmHalfClosedLocal
    of seEndStreamRecv:
      strmHalfClosedRemote
    of seRstStream:
      strmClosed
    else:
      strmOpen
  of strmClosed:
    case e
    # XXX allow Flow-controlled frames recv
    of sePrioritySend,
        sePriorityRecv,
        seWindowUpdateRecv,
        seRstStream:
      strmClosed
    # XXX this is like limiting the window
    #     to receive after close to 0.
    #     Maybe just ignore all received?
    #     however, in case of sending
    #     is correct, and in case of
    #     receiving, it should be handled
    #     by the receiver...?
    else:
      strmInvalid
  of strmReservedLocal:
    case e
    of seHeadersSend:
      strmHalfClosedRemote
    of seRstStream:
      strmClosed
    of sePrioritySend,
        sePriorityRecv,
        seWindowUpdateRecv:
      strmReservedLocal
    else:
      strmInvalid
  of strmReservedRemote:
    case e
    of seHeadersRecv:
      strmHalfClosedLocal
    of seRstStream:
      strmClosed
    of seWindowUpdateSend,
        sePriorityRecv,
        sePrioritySend:
      strmReservedRemote
    else:
      strmInvalid
  of strmHalfClosedLocal:
    case e
    of seEndStreamRecv,
        seRstStream:
      strmClosed
    # can receive any type
    of seHeadersRecv,
        sePushPromiseRecv,
        sePriorityRecv,
        seWindowUpdateRecv,
        seWindowUpdateSend,
        sePrioritySend:
      strmHalfClosedLocal
    else:
      strmInvalid
  of strmHalfClosedRemote:
    case e
    of seEndStreamSend,
        seRstStream:
      strmClosed
    # can send any type
    of seHeadersSend,
        sePushPromiseSend,
        sePrioritySend,
        seWindowUpdateSend,
        seWindowUpdateRecv,
        sePriorityRecv:
      strmHalfClosedRemote
    else:
      strmInvalid
  of strmInvalid:
    #assert false
    strmInvalid

func toEventRecv(frm: Frame): StreamEvent =
  case frm.typ
  of frmtData:
    if frmfEndStream in frm.flags:
      seEndStreamRecv
    else:
      seDataRecv
  of frmtHeaders:
    # XXX needs fixing if ES can be in
    #     a continuation frm
    if frmfEndStream in frm.flags:
      seEndStreamRecv
    else:
      seHeadersRecv
  of frmtPriority:
    sePriorityRecv
  of frmtRstStream:
    seRstStream
  of frmtPushPromise:
    sePushPromiseRecv
  of frmtWindowUpdate:
    seWindowUpdateRecv
  else:
    doAssert frm.typ in {frmtSettings, frmtPing, frmtGoAway, frmtContinuation}
    doAssert false
    seUnknown

func isAllowedToSend(state: StreamState, frm: Frame): bool =
  ## Check if the stream is allowed to send the frame
  true

func isAllowedToRecv(state: StreamState, frm: Frame): bool =
  ## Check if the stream is allowed to receive the frame
  # https://httpwg.org/specs/rfc9113.html#StreamStates
  case state
  of strmIdle:
    frm.typ in {frmtHeaders, frmtPriority}
  of strmReservedLocal:
    frm.typ in {frmtRstStream, frmtPriority, frmtWindowUpdate}
  of strmReservedRemote:
    frm.typ in {frmtHeaders, frmtRstStream, frmtPriority}
  of strmOpen, strmHalfClosedLocal:
    true
  of strmHalfClosedRemote:
    frm.typ in {frmtWindowUpdate, frmtPriority, frmtRstStream}
  of strmClosed:  # XXX only do minimal processing of frames
    true
  of strmInvalid: false

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
    raiseError CompressionError, err.msg

type
  Payload = ref object
    s: seq[byte]
  Response* = ref object
    headers: DecodedStr
    data: Payload

func newPayload(): Payload =
  Payload()

func newResponse(): Response =
  Response(headers: initDecodedStr())

type
  Stream = object
    id: StreamId
    state: StreamState
    recvData: FutureVar[Response]
    isConsumed: FutureVar[void]

proc read(s: Stream): Future[Response] {.async.} =
  result = await Future[Response](s.recvData)
  s.recvData.clean()
  s.isConsumed.complete()

proc doTransitionSend(s: var Stream, frm: Frame) =
  discard

const connFrmAllowed = {
  frmtSettings,
  frmtPing,
  frmtGoAway,
  frmtWindowUpdate
}
const strmFrmAllowed = {
  frmtData,
  frmtHeaders,
  frmtPriority,
  frmtRstStream,
  frmtPushPromise,
  frmtWindowUpdate
  #frmtContinuation
}

proc doTransitionRecv(s: var Stream, frm: Frame) =
  if s.id == frmsidMain.StreamId:
    check(frm.typ in connFrmAllowed, ProtocolError)
    return
  check(frm.typ in strmFrmAllowed, ProtocolError)
  if not s.state.isAllowedToRecv frm:
    if s.state == strmHalfClosedRemote:
      raiseError StrmStreamClosedError
    else:
      raiseError ProtocolError
  let event = frm.toEventRecv()
  let oldState = s.state
  s.state = transition(s.state, event)
  check(s.state != strmInvalid, ProtocolError)
  if oldState == strmIdle:
    # XXX close streams < s.id in idle state
    discard

type
  MsgData = object
    strmId: StreamId
    frmTyp: FrmTyp
    payload: Payload
  ClientContext* = ref object
    sock: AsyncSocket
    hostname: string
    port: Port
    isConnected: bool
    dynHeaders: DynHeaders
    streams: Table[StreamId, Stream]
    currStreamId: StreamId
    maxConcurrentStreams: int
    msgBuff: QueueAsync[MsgData]

proc newSocket(): AsyncSocket =
  result = newAsyncSocket()
  wrapSocket(defaultSslContext(), result)

proc newClient*(hostname: string, port = Port 443): ClientContext =
  result = ClientContext(
    sock: newSocket(),
    hostname: hostname,
    port: port,
    dynHeaders: initDynHeaders(1024, 16),
    streams: initTable[StreamId, Stream](16),
    currStreamId: 1.StreamId,
    maxConcurrentStreams: 256,
    msgBuff: newQueue[MsgData](10)
  )

proc initStream(id: StreamId): Stream =
  result = Stream(
    id: id,
    state: strmIdle,
    recvData: newFutureVar[Response]("Stream.recvData"),
    isConsumed: newFutureVar[void]("Stream.isConsumed"))
  result.isConsumed.complete()

func stream(client: ClientContext, sid: StreamId): var Stream =
  try:
    result = client.streams[sid]
  except KeyError:
    raiseError ProtocolError

func stream(client: ClientContext, sid: FrmSid): var Stream =
  client.stream sid.StreamId

proc readUntilEnd(client: ClientContext, frm: Frame, payload: Payload) {.async.} =
  ## Read continuation frames until ``END_HEADERS`` flag is set
  assert frm.typ == frmtHeaders or frm.typ == frmtPushPromise
  assert frmfEndHeaders notin frm.flags
  let sid = frm.sid
  while frmfEndHeaders notin frm.flags:
    doAssert frm.rawLen >= frmHeaderSize
    frm.setRawBytes(await client.sock.recv(frmHeaderSize))
    check(frm.rawLen > 0, ConnectionClosedError)
    debugInfo $frm
    check(frm.sid == sid, ProtocolError)
    check(frm.typ == frmtContinuation, ProtocolError)
    check frm.payloadLen >= 0
    if frm.payloadLen == 0:
      continue
    payload.s.add(await client.sock.recv(frm.payloadLen.int))
    check(payload.s.len > 0, ConnectionClosedError)

proc read(client: ClientContext, frm: Frame, payload: Payload) {.async.} =
  ## Read a frame + payload. If read frame is a ``Header`` or
  ## ``PushPromise``, read frames until ``END_HEADERS`` flag is set
  ## Frames cannot be interleaved here
  doAssert frm.rawLen >= frmHeaderSize
  frm.setRawBytes await client.sock.recv(frmHeaderSize)
  check(frm.rawLen > 0, ConnectionClosedError)
  debugInfo $frm
  check frm.payloadLen >= 0
  if frm.payloadLen > 0:
    payload.s.setLen 0
    payload.s.add await client.sock.recv(frm.payloadLen.int)
    check(payload.s.len > 0, ConnectionClosedError)
    debugInfo toString(frm, payload.s)
  let frmTyp = frm.typ
  case frm.typ
  of frmtHeaders, frmtPushPromise:
    if frmfPadded in frm.flags:
      debugInfo "PADDED"  # XXX consume padding
    if frmfEndHeaders notin frm.flags:
      debugInfo "Continuation"
      await client.readUntilEnd(frm, payload)
  else:
    discard
  # transition may raise a stream error, so do after processing
  # all continuation frames
  #client.stream(frm.sid).doTransitionRecv frmTyp  # XXX fix

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

proc write(client: ClientContext, frm: Frame) {.async.} =
  client.stream(frm.sid).doTransitionSend frm
  await client.sock.send(frm.rawBytesPtr, frm.rawLen)

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
  # await handshake()

proc close(client: ClientContext) =
  client.sock.close()

proc responseDispatcherNaked(client: ClientContext) {.async.} =
  while client.isConnected:
    let data = await client.msgBuff.pop()
    if data.strmId notin client.streams:
      debugInfo "stream not found " & $data.strmId.int
      continue
    debugInfo "recv data on stream " & $data.strmId.int
    let stream = client.streams[data.strmId]
    if not stream.isConsumed.finished:
      await Future[void](stream.isConsumed)
    #doAssert stream.recvData.finished
    stream.isConsumed.clean()
    stream.recvData.clean()
    var resp = newResponse()
    #resp.data = payload
    try:
      if data.frmTyp == frmtHeaders:
        decode(data.payload.s, resp.headers, client.dynHeaders)
      stream.recvData.complete resp
    except CompressionError as err:
      Future[Response](stream.recvData).fail err

proc responseDispatcher(client: ClientContext) {.async.} =
  try:
    await client.responseDispatcherNaked()
  except Exception as err:
    debugInfo err.msg
    raise err
  finally:
    debugInfo "responseDispatcher exited"

proc recvTaskNaked(client: ClientContext) {.async.} =
  ## Receive frames and dispatch to opened streams
  ## Meant to be asyncCheck'ed
  doAssert client.isConnected
  var frm = newFrame()
  while client.isConnected:
    frm.clear()
    var payload = newPayload()  # XXX remove
    try:
      await client.read(frm, payload)
    except OSError as err:
      if not client.isConnected:
        debugInfo "not connected"
        break
      raise err
    await client.msgBuff.put MsgData(
      strmId: frm.sid.StreamId,
      frmTyp: frm.typ,
      payload: payload
    )

proc recvTask(client: ClientContext) {.async.} =
  try:
    await client.recvTaskNaked()
  except Exception as err:
    debugInfo err.msg
    raise err
  finally:
    debugInfo "recvTask exited"

proc consumeMainStreamNaked(client: ClientContext) {.async.} =
  # XXX process settings, window updates, etc
  doAssert client.isConnected
  while client.isConnected:
    discard await client.stream(frmsidMain.StreamId).read()

proc consumeMainStream(client: ClientContext) {.async.} =
  try:
    await client.consumeMainStreamNaked()
  except Exception as err:
    debugInfo err.msg
    raise err
  finally:
    debugInfo "consumeMainStream exited"

template withConnection*(
  client: ClientContext,
  body: untyped
) =
  var recvFut: Future[void]
  var waitForRecvFut = false
  try:
    debugInfo "connecting"
    await client.connect()
    debugInfo "connected"
    recvFut = client.recvTask()
    waitForRecvFut = true
    asyncCheck client.consumeMainStream()
    asyncCheck client.responseDispatcher()
    block:
      body
  except Exception as err:
    debugInfo err.msg
    raise err
  finally:
    debugInfo "exit"
    client.close()
    client.isConnected = false
    if waitForRecvFut:
      await recvFut

type
  Request* = ref object
    data: seq[byte]

func newRequest(): Request =
  Request()

func addHeader(client: ClientContext, r: Request, n, v: string) =
  discard hencode(n, v, client.dynHeaders, r.data, huffman = false)

proc request(client: ClientContext, req: Request): Future[Response] {.async.} =
  let sid = client.openStream()
  doAssert sid.FrmSid != frmsidMain
  var frm = newFrame()
  frm.setTyp frmtHeaders
  frm.setSid sid.FrmSid
  frm.flags.incl frmfEndHeaders
  frm.add req.data
  await client.write frm
  result = await client.stream(sid).read()
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

when isMainModule:
  proc main() {.async.} =
    var client = newClient("google.com")
    withConnection(client):
      let r = await client.get("/")
      echo r.headers
      #echo r.data  # XXX set from Data frame, not headers
      await sleepAsync 2000
  waitFor main()
  echo "ok"
