## Functionality shared beetwen client and server

when not defined(ssl):
  {.error: "this lib needs -d:ssl".}

import std/asyncdispatch
import std/asyncnet
import std/openssl
import std/net

import pkg/hpack

import ./frame
import ./stream
import ./queue
import ./errors
import ./utils

when defined(hyperxTest):
  import ./testsocket

proc SSL_CTX_set_options*(ctx: SslCtx, options: clong): clong {.cdecl, dynlib: DLLSSLName, importc.}
const SSL_OP_NO_RENEGOTIATION* = 1073741824
const SSL_OP_NO_SESSION_RESUMPTION_ON_RENEGOTIATION* = 65536

# XXX remove
func toBytes(s: string): seq[byte] {.compileTime.} =
  result = newSeq[byte]()
  for c in s:
    result.add c.byte

const
  preface* = "PRI * HTTP/2.0\r\L\r\LSM\r\L\r\L".toBytes
  statusLineLen* = ":status: xxx\r\n".len
  # https://httpwg.org/specs/rfc9113.html#SettingValues
  stgHeaderTableSize* = 4096'u32
  stgMaxConcurrentStreams* = uint32.high
  stgInitialWindowSize* = (1'u32 shl 16) - 1'u32
  stgMaxWindowSize* = (1'u32 shl 31) - 1'u32
  stgInitialMaxFrameSize* = 1'u32 shl 14
  stgMaxFrameSize* = (1'u32 shl 24) - 1'u32
  stgDisablePush* = 0'u32

template debugInfo*(s: string): untyped =
  when defined(hyperxDebug):
    debugEcho s
  else:
    discard

template check*(cond: bool): untyped =
  {.line: instantiationInfo(fullPaths = true).}:
    if not cond:
      raise (ref HyperxError)()

template check*(cond: bool, errObj: untyped): untyped =
  {.line: instantiationInfo(fullPaths = true).}:
    if not cond:
      raise errObj

func add*(s: var seq[byte], ss: string) {.raises: [].} =
  # XXX x_x
  for c in ss:
    s.add c.byte

func add*(s: var string, ss: openArray[byte]) {.raises: [].} =
  # XXX x_x
  for c in ss:
    s.add c.char

type
  ClientTyp* = enum
    ctServer, ctClient

proc sslContextAlpnSelect(
  ssl: SslPtr;
  outProto: ptr cstring;
  outlen: cstring;  # ptr char
  inProto: cstring;
  inlen: cuint;
  arg: pointer
): cint {.cdecl.} =
  const h2Alpn = "\x02h2"  # len + proto_name
  const h2AlpnL = h2Alpn.len
  var i = 0
  while i+h2AlpnL-1 < inlen.int:
    if h2Alpn == toOpenArray(inProto, i, i+h2AlpnL-1):
      outProto[] = cast[cstring](addr inProto[i+1])
      cast[ptr char](outlen)[] = inProto[i]
      return SSL_TLSEXT_ERR_OK
    i += inProto[i].int + 1
  return SSL_TLSEXT_ERR_NOACK

proc defaultSslContext*(
  clientTyp: ClientTyp,
  certFile = "",
  keyFile = ""
): SslContext {.raises: [InternalSslError].} =
  # protSSLv23 will disable all protocols
  # lower than the min protocol defined
  # in openssl.config, usually +TLSv1.2
  try:
    result = newContext(
      protSSLv23,
      verifyMode = CVerifyPeer,
      certFile = certFile,
      keyFile = keyFile
    )
  except CatchableError as err:
    raise newException(InternalSslError, err.msg)
  except Defect as err:
    raise err
  except Exception as err:
    # workaround for newContext raising Exception
    raise newException(Defect, err.msg)
  doAssert result != nil, "failure to initialize the SSL context"
  # https://httpwg.org/specs/rfc9113.html#tls12features
  discard SSL_CTX_set_options(
    result.context,
    SSL_OP_ALL or SSL_OP_NO_SSLv2 or SSL_OP_NO_SSLv3 or
    SSL_OP_NO_RENEGOTIATION or
    SSL_OP_NO_SESSION_RESUMPTION_ON_RENEGOTIATION
  )
  case clientTyp
  of ctServer:
    discard SSL_CTX_set_alpn_select_cb(
      result.context, sslContextAlpnSelect, nil
    )
  of ctClient:
    var openSslVersion = 0.culong
    untrackExceptions:
      openSslVersion = getOpenSSLVersion()
    doAssert openSslVersion >= 0x10002000
    discard SSL_CTX_set_alpn_protos(
      result.context, "\x02h2", 3
    )

when defined(hyperxTest):
  type MyAsyncSocket* = TestSocket
else:
  type MyAsyncSocket* = AsyncSocket

type
  ClientContext* = ref object
    typ: ClientTyp
    sock*: MyAsyncSocket
    hostname*: string
    port: Port
    isConnected*: bool
    headersEnc, headersDec: DynHeaders
    streams: Streams
    sendMsgs, recvMsgs: QueueAsync[Frame]
    streamOpenedMsgs*: QueueAsync[StreamId]
    currStreamId, maxPeerStrmIdSeen: StreamId
    peerMaxConcurrentStreams: uint32
    peerWindowSize: uint32
    peerMaxFrameSize: uint32
    exitError*: ref HyperxError

proc newClient*(
  typ: ClientTyp,
  sock: MyAsyncSocket,
  hostname: string,
  port = Port 443
): ClientContext {.raises: [].} =
  result = ClientContext(
    typ: typ,
    sock: sock,
    hostname: hostname,
    port: port,
    isConnected: false,
    headersEnc: initDynHeaders(stgHeaderTableSize.int),
    headersDec: initDynHeaders(stgHeaderTableSize.int),
    streams: initStreams(),
    currStreamId: 1.StreamId,
    recvMsgs: newQueue[Frame](10),
    sendMsgs: newQueue[Frame](10),
    streamOpenedMsgs: newQueue[StreamId](10),
    maxPeerStrmIdSeen: 0.StreamId,
    peerMaxConcurrentStreams: stgMaxConcurrentStreams,
    peerWindowSize: stgInitialWindowSize,
    peerMaxFrameSize: stgInitialMaxFrameSize
  )

proc close*(client: ClientContext) {.raises: [InternalOsError].} =
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
    client.streamOpenedMsgs.close()

func stream*(client: ClientContext, sid: StreamId): var Stream {.raises: [].} =
  client.streams.get sid

func stream*(client: ClientContext, sid: FrmSid): var Stream {.raises: [].} =
  client.stream sid.StreamId

proc close*(client: ClientContext, sid: StreamId) {.raises: [].} =
  # Close stream messages queue and delete stream from
  # the client.
  # This does nothing if the stream is already close
  client.streams.close sid

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

func hpackDecode(
  client: ClientContext,
  ds: var DecodedStr,
  payload: openArray[byte]
) {.raises: [ConnError].} =
  try:
    hdecodeAll(payload, client.headersDec, ds)
  except HpackError as err:
    debugInfo err.msg
    raise newConnError(errCompressionError)

func hpackEncode*(
  client: ClientContext,
  payload: var seq[byte],  # XXX var string
  name, value: openArray[char]
) {.raises: [HyperxError].} =
  ## headers must be added synchronously, no await in between,
  ## or else a table resize could occur in the meantime
  try:
    discard hencode(name, value, client.headersEnc, payload, huffman = false)
  except HpackError as err:
    raise newException(HyperxError, err.msg)

proc handshake*(client: ClientContext) {.async.} =
  doAssert client.isConnected
  debugInfo "handshake"
  # we need to do this before sending any other frame
  # XXX: allow sending some params
  let sid = client.openMainStream()
  doAssert sid == frmSidMain.StreamId
  var frm = newSettingsFrame()
  if client.typ == ctClient:
    frm.addSetting frmsEnablePush, stgDisablePush
  frm.addSetting frmsInitialWindowSize, stgMaxWindowSize
  var blob = newSeqOfCap[byte](preface.len+frm.len)
  if client.typ == ctClient:
    blob.add preface
  blob.add frm.s
  check not client.sock.isClosed, newConnClosedError()
  await client.sock.send(addr blob[0], blob.len)
  if client.typ == ctServer:
    blob.setLen preface.len
    check not client.sock.isClosed, newConnClosedError()
    let blobRln = await client.sock.recvInto(addr blob[0], blob.len)
    check blobRln == blob.len, newConnClosedError()
    check blob == preface, newConnError(errProtocolError)

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
#     similar to a stream i.e: if frm without end is
#     found consume from streamContinuations
proc write*(client: ClientContext, frm: Frame) {.async.} =
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
  await client.sendMsgs.put frm

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

proc readNaked(client: ClientContext, sid: StreamId): Future[Frame] {.async.} =
  let frm = await client.stream(sid).msgs.pop()
  doAssert sid == frm.sid.StreamId
  # this may throw a conn error
  client.stream(sid).doTransitionRecv frm
  if frm.typ == frmtWindowUpdate:
    check frm.payload.len > 0, newStrmError(errProtocolError)
  if frm.typ == frmtData and
      frm.payloadLen.int > 0 and
      frmfEndStream notin frm.flags:
    await client.write newWindowUpdateFrame(sid.FrmSid, frm.payloadLen.int)
  return frm

proc read*(client: ClientContext, sid: StreamId): Future[Frame] {.async.} =
  try:
    result = await client.readNaked(sid)
  except QueueClosedError as err:
    doAssert not client.isConnected
    if client.exitError != nil:
      # xxx change to connError
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

proc sendTaskNaked(client: ClientContext) {.async.} =
  ## Send frames
  ## Meant to be asyncCheck'ed
  doAssert client.isConnected
  while client.isConnected:
    let frm = await client.sendMsgs.pop()
    doAssert frm.payloadLen.int == frm.payload.len
    doAssert frm.payload.len <= client.peerMaxFrameSize.int
    check not client.sock.isClosed, newConnClosedError()
    await client.sock.send(frm.rawBytesPtr, frm.len)

proc sendTask*(client: ClientContext) {.async.} =
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

proc recvTaskNaked(client: ClientContext) {.async.} =
  ## Receive frames and dispatch to opened streams
  ## Meant to be asyncCheck'ed
  doAssert client.isConnected
  while client.isConnected:
    var frm = newFrame()
    await client.read frm
    await client.recvMsgs.put frm

proc recvTask*(client: ClientContext) {.async.} =
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
        case client.typ
        of ctClient:
          check value == 0, newConnError(errProtocolError)
        of ctServer:
          check value == 0 or value == 1, newConnError(errProtocolError)
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
    if frmfAck notin frm.flags:
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

proc recvDispatcherNaked(client: ClientContext) {.async.} =
  ## Dispatch messages to open streams.
  ## Note decoding headers must be done in message received order,
  ## so it needs to be done here. Same for processing the main
  ## stream messages.
  while client.isConnected:
    let frm = await client.recvMsgs.pop()
    debugInfo "recv data on stream " & $frm.sid.int
    if frm.sid == frmSidMain:
      # Settings need to be applied before consuming following messages
      await consumeMainStream(client, frm)
      continue
    if client.typ == ctServer and
        frm.sid.StreamId > client.maxPeerStrmIdSeen and
        frm.sid.int mod 2 != 0:
      client.maxPeerStrmIdSeen = frm.sid.StreamId
      # we do not store idle streams, so no need to close them
      client.streams.open(frm.sid.StreamId)
      await client.streamOpenedMsgs.put frm.sid.StreamId
    if client.typ == ctClient and
        frm.sid.StreamId > client.maxPeerStrmIdSeen and
        frm.sid.int mod 2 == 0:
      client.maxPeerStrmIdSeen = frm.sid.StreamId
    if frm.typ == frmtHeaders:
      # XXX implement initDecodedBytes as seq[byte] in hpack
      var headers = initDecodedStr()
      # can raise a connError
      client.hpackDecode(headers, frm.payload)
      frm.shrink frm.payload.len
      frm.s.add $headers
    if frm.typ == frmtData and frm.payloadLen.int > 0:
      await client.write newWindowUpdateFrame(frmSidMain, frm.payloadLen.int)
    # XXX implement flow control
    if frm.typ == frmtWindowUpdate:
      continue
    # Process headers even if the stream
    # does not exist
    if frm.sid.StreamId notin client.streams:
      # XXX need to reply as closed stream ?
      debugInfo "stream not found " & $frm.sid.int
      continue
    let stream = client.streams.get frm.sid.StreamId
    try:
      # XXX a stream can block all streams here,
      #     no way around it. Maybe it can be avoided with
      #     window update deafult or min size?
      await stream.msgs.put frm
    except QueueClosedError:
      debugInfo "stream is closed " & $frm.sid.int

proc recvDispatcher*(client: ClientContext) {.async.} =
  # XXX always store exitError for all errors
  #     everywhere where queues are closed
  try:
    await client.recvDispatcherNaked()
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

template withClient*(client: ClientContext, body: untyped) =
  doAssert not client.isConnected
  var sendFut, recvFut, dispFut: Future[void]
  try:
    client.isConnected = true
    if client.typ == ctClient:
      await client.sock.connect(client.hostname, client.port)
    await client.handshake()
    sendFut = client.sendTask()
    recvFut = client.recvTask()
    dispFut = client.recvDispatcher()
    block:
      body
  except QueueClosedError as err:
    doAssert not client.isConnected
    raise err
  except CatchableError as err:
    debugInfo err.msg
    raise err
  finally:
    client.close()
    # XXX do gracefull shutdown with timeout,
    #     wait for send/recv to drain the queue
    #     before closing
    
    # do not bother the user with hyperx errors
    # at this point body completed or errored out
    for fut in [sendFut, recvFut, dispFut]:
      try:
        if fut != nil:
          await fut
      except HyperxError as err:
        debugInfo err.msg

type
  ClientStreamState* = enum
    csStateInitial,
    csStateOpened,
    csStateSentHeaders,
    csStateSentData,
    csStateSentEnded,
    csStateRecvHeaders,
    csStateRecvData,
    csStateRecvEnded
  ClientStream* = ref object
    client*: ClientContext
    sid*: StreamId
    state*: ClientStreamState

func newClientStream*(client: ClientContext, sid: StreamId): ClientStream =
  ClientStream(
    client: client,
    sid: sid,
    state: csStateInitial
  )

func newClientStream*(client: ClientContext): ClientStream =
  let sid = client.openStream()
  newClientStream(client, sid)

proc close*(strm: ClientStream) =
  strm.client.close(strm.sid)

func recvEnded*(strm: ClientStream): bool =
  strm.state == csStateRecvEnded

proc recvHeaders*(strm: ClientStream, data: ref string) {.async.} =
  case strm.client.typ
  of ctClient: doAssert strm.state == csStateSentEnded
  of ctServer: doAssert strm.state == csStateOpened
  strm.state = csStateRecvHeaders
  # https://httpwg.org/specs/rfc9113.html#HttpFraming
  var frm: Frame
  while true:
    frm = await strm.client.read(strm.sid)
    check frm.typ == frmtHeaders, newStrmError(errProtocolError)
    if strm.client.typ == ctServer:
      break
    check frm.payload.len >= statusLineLen, newStrmError(errProtocolError)
    #check frm.payload.startsWith ":status: ", newStrmError(errProtocolError)
    if frm.payload[9] == '1'.byte:
      check frmfEndStream notin frm.flags, newStrmError(errProtocolError)
    else:
      break
  data[].add frm.payload
  if frmfEndStream in frm.flags:
    strm.state = csStateRecvEnded

proc recvBody*(strm: ClientStream, data: ref string) {.async.} =
  doAssert strm.state in {csStateRecvHeaders, csStateRecvData}
  strm.state = csStateRecvData
  let frm = await strm.client.read(strm.sid)
  # XXX store trailer headers
  # https://www.rfc-editor.org/rfc/rfc9110.html#section-6.5
  if frm.typ == frmtHeaders:
    check frmfEndStream in frm.flags, newStrmError(errProtocolError)
    strm.state = csStateRecvEnded
    return
  check frm.typ == frmtData, newStrmError(errProtocolError)
  data[].add frm.payload
  if frmfEndStream in frm.flags:
    strm.state = csStateRecvEnded

proc sendHeaders*(
  strm: ClientStream,
  headers: ref seq[byte],  # XXX ref string
  finish: bool
) {.async.} =
  ## Headers must be HPACK encoded
  template client: untyped = strm.client
  case strm.client.typ
  of ctClient: doAssert strm.state == csStateOpened
  of ctServer: doAssert strm.state == csStateRecvEnded
  strm.state = csStateSentHeaders
  var frm = newFrame()
  frm.add headers[]
  frm.setTyp frmtHeaders
  frm.setSid strm.sid.FrmSid
  frm.setPayloadLen frm.payloadSize.FrmPayloadLen
  frm.flags.incl frmfEndHeaders
  if finish:
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

template withStream*(strm: ClientStream, body: untyped): untyped =
  doAssert strm.state == csStateInitial
  strm.state = csStateOpened
  try:
    block:
      body
    case strm.client.typ
    of ctClient: doAssert strm.state == csStateRecvEnded
    of ctServer: doAssert strm.state == csStateSentEnded
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

  import std/net

  block default_settings:
    doAssert stgHeaderTableSize == 4096'u32
    doAssert stgMaxConcurrentStreams == uint32.high
    doAssert stgInitialWindowSize == 65_535'u32
    doAssert stgMaxWindowSize == 2_147_483_647'u32
    doAssert stgInitialMaxFrameSize == 16_384'u32
    doAssert stgMaxFrameSize == 16_777_215'u32
    doAssert stgDisablePush == 0'u32

  echo "ok"
