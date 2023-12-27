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

type
  HyperxError* = object of CatchableError
  ConnError = object of HyperxError
  ConnClosedError = object of ConnError
  ConnProtocolError = object of ConnError
  ConnStreamClosedError = object of ConnError
  ConnCompressionError = object of ConnError
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
    raiseError ConnCompressionError, err.msg

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
    check(frm.typ in connFrmAllowed, ConnProtocolError)
    return
  check(frm.typ in frmRecvAllowed, ConnProtocolError)
  if not s.state.isAllowedToRecv frm:
    if s.state == strmHalfClosedRemote:
      raiseError StrmStreamClosedError
    else:
      raiseError ConnProtocolError
  let event = frm.toEventRecv()
  let oldState = s.state
  s.state = s.state.toNextStateRecv event
  check(s.state != strmInvalid, ConnProtocolError)
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
    dynHeaders: DynHeaders
    streams: Table[StreamId, Stream]
    currStreamId: StreamId
    maxConcurrentStreams: int
    dptMsgs: QueueAsync[DptMsgData]
    writeLock: LockAsync

when not defined(hyperxTest):
  proc newMySocket(): MyAsyncSocket =
    result = newAsyncSocket()
    wrapSocket(defaultSslContext(), result)

proc newClient*(hostname: string, port = Port 443): ClientContext =
  result = ClientContext(
    sock: newMySocket(),
    hostname: hostname,
    port: port,
    dynHeaders: initDynHeaders(1024, 16),
    streams: initTable[StreamId, Stream](16),
    currStreamId: 1.StreamId,
    maxConcurrentStreams: 256,
    dptMsgs: newQueue[DptMsgData](10),
    writeLock: newLock()
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
    raiseError ConnProtocolError

func stream(client: ClientContext, sid: FrmSid): var Stream =
  client.stream sid.StreamId

proc readUntilEnd(client: ClientContext, frm: Frame, payload: Payload) {.async.} =
  ## Read continuation frames until ``END_HEADERS`` flag is set
  assert frm.typ in {frmtHeaders, frmtPushPromise}
  assert frmfEndHeaders notin frm.flags
  var frm2 = newFrame()
  while frmfEndHeaders notin frm2.flags:
    frm2.setRawBytes await client.sock.recv(frmHeaderSize)
    check(frm2.rawLen == frmHeaderSize, ConnClosedError)
    debugInfo $frm2
    check(frm2.sid == frm.sid, ConnProtocolError)
    check(frm2.typ == frmtContinuation, ConnProtocolError)
    check frm2.payloadLen >= 0
    if frm2.payloadLen == 0:
      continue
    payload.s.add await client.sock.recv(frm2.payloadLen.int)
    check(payload.s.len == frm2.payloadLen.int, ConnClosedError)

proc read(client: ClientContext, frm: Frame, payload: Payload) {.async.} =
  ## Read a frame + payload. If read frame is a ``Header`` or
  ## ``PushPromise``, read frames until ``END_HEADERS`` flag is set
  ## Frames cannot be interleaved here
  # XXX: use recvInto
  frm.setRawBytes await client.sock.recv(frmHeaderSize)
  check(frm.rawLen == frmHeaderSize, ConnClosedError)
  debugInfo $frm
  if frmfPadded in frm.flags:
    check(frm.typ in {frmtHeaders, frmtPushPromise, frmtData}, ConnProtocolError)
    let padding = await client.sock.recv(1)
    check(padding.len == 1, ConnClosedError)
    frm.setPadding padding[0].uint8
  check frm.payloadLen >= 0
  if frm.payloadLen > 0:
    payload.s.setLen 0
    payload.s.add await client.sock.recv(frm.payloadLen.int)
    check(payload.s.len == frm.payloadLen.int, ConnClosedError)
    debugInfo toString(frm, payload.s)
  if frmfPadded in frm.flags:
    let padding = await client.sock.recv(frm.padding.int)
    check(padding.len == frm.padding.int, ConnClosedError)
  case frm.typ
  of frmtHeaders, frmtPushPromise:
    if frmfEndHeaders notin frm.flags:
      debugInfo "Continuation"
      await client.readUntilEnd(frm, payload)
  else:
    discard
  # transition may raise a stream error, so do after processing
  # all continuation frames. Code before this can only raise
  # conn errors
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
  # await handshake()

proc close(client: ClientContext) =
  client.sock.close()

proc consumeMainStream(client: ClientContext, dptMsg: DptMsgData) {.async.} =
  # XXX process settings, window updates, etc
  discard

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
    let stream = client.streams[dptMsg.strmId]
    var strmMsg = initStrmMsgData(dptMsg.frmTyp)
    if dptMsg.frmTyp == frmtHeaders:
      # XXX implement initDecodedBytes as seq[byte] in hpack
      var headers = initDecodedStr()
      try:
        decode(dptMsg.payload.s, headers, client.dynHeaders)
        strmMsg.payload.s.add $headers
      except ConnCompressionError as err:
        # XXX propagate error in strmMsg
        discard
    else:
      strmMsg.payload = dptMsg.payload
    await stream.strmMsgs.put strmMsg

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
    await client.dptMsgs.put DptMsgData(
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

template withConnection*(
  client: ClientContext,
  body: untyped
) =
  block:
    var recvFut: Future[void]
    var waitForRecvFut = false
    try:
      debugInfo "connecting"
      await client.connect()
      debugInfo "connected"
      recvFut = client.recvTask()
      waitForRecvFut = true
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
      try:
        if waitForRecvFut:
          await recvFut
      except ConnClosedError:
        discard

type
  Request* = ref object
    data: seq[byte]

func newRequest(): Request =
  Request()

func addHeader(client: ClientContext, r: Request, n, v: string) =
  discard hencode(n, v, client.dynHeaders, r.data, huffman = false)

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
  proc putTestData*(client: ClientContext, data: string) =
    discard

when isMainModule:
  when not defined(hyperxTest):
    {.error: "tests need -d:hyperxTest".}
  
  template test(name: string, body: untyped): untyped =
    block:
      echo "test " & name
      body

  test "sock default state":
    var client = newClient("google.com")
    doAssert not client.sock.isConnected
    doAssert client.sock.hostname == ""
    doAssert client.sock.port == Port 0
  test "sock state":
    proc test() {.async.} =
      var client = newClient("google.com")
      withConnection client:
        doAssert client.sock.isConnected
        doAssert client.sock.hostname == "google.com"
        doAssert client.sock.port == Port 443
      doAssert not client.sock.isConnected
    waitFor test()

  echo "ok"
