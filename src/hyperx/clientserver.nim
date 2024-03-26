
import ./frame
import ./stream
import ./queue
import ./errors

const
  preface* = "PRI * HTTP/2.0\r\L\r\LSM\r\L\r\L"
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
  if not cond:
    raise (ref HyperxError)()

template check*(cond: bool, errObj: untyped): untyped =
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

when defined(hyperxTest):
  type MyAsyncSocket* = TestSocket
else:
  type MyAsyncSocket* = AsyncSocket

type
  ClientContext* = ref object
    sock: MyAsyncSocket
    hostname: string
    port: Port
    isConnected: bool
    headersEnc, headersDec: DynHeaders
    streams: Streams
    currStreamId: StreamId
    sendMsgs, recvMsgs: QueueAsync[Frame]
    maxPeerStrmIdSeen: StreamId
    peerMaxConcurrentStreams: uint32
    peerWindowSize: uint32
    peerMaxFrameSize: uint32
    exitError: ref HyperxError

proc newClient*(
  sock: MyAsyncSocket,
  hostname: string,
  port = Port 443
): ClientContext {.raises: [InternalOsError].} =
  result = ClientContext(
    sock: sock,
    hostname: hostname,
    port: port,
    headersEnc: initDynHeaders(stgHeaderTableSize.int),
    headersDec: initDynHeaders(stgHeaderTableSize.int),
    streams: initStreams(),
    currStreamId: 1.StreamId,
    recvMsgs: newQueue[Frame](10),
    sendMsgs: newQueue[Frame](10),
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

func stream*(client: ClientContext, sid: StreamId): var Stream {.raises: [].} =
  client.streams.get sid

func stream*(client: ClientContext, sid: FrmSid): var Stream {.raises: [].} =
  client.stream sid.StreamId

proc close*(client: ClientContext, sid: StreamId) {.raises: [].} =
  # Close stream messages queue and delete stream from
  # the client.
  # This does nothing if the stream is already close
  client.streams.close sid

proc handshake*(client: ClientContext) {.async.} =
  doAssert client.isConnected
  debugInfo "handshake"
  # we need to do this before sending any other frame
  # XXX: allow sending some params
  let sid = client.openMainStream()
  doAssert sid == frmSidMain.StreamId
  var frm = newSettingsFrame()
  # XXX for servers this must be 0 (disabled) or not send it
  frm.addSetting frmsEnablePush, stgDisablePush
  frm.addSetting frmsInitialWindowSize, stgMaxWindowSize
  var blob = newSeqOfCap[byte](preface.len+frm.len)
  blob.add preface
  blob.add frm.s
  check not client.sock.isClosed, newConnClosedError()
  await client.sock.send(addr blob[0], blob.len)

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
        # XXX servers can receive 1
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
      # XXX a stream can block all streams here,
      #     no way around it. Maybe it can be avoided with
      #     window update deafult or min size?
      await stream.msgs.put frm
    except QueueClosedError:
      debugInfo "stream is closed " & $frm.sid.int

proc recvDispatcher*(client: ClientContext) {.async.} =
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

