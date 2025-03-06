## Functionality shared between client and server

import std/asyncdispatch
import std/asyncnet
import std/net
when defined(ssl):
  import std/openssl

import pkg/hpack

import ./frame
import ./stream
import ./value
import ./signal
import ./errors
import ./utils

when defined(hyperxTest):
  import ./testsocket

definedSsl:
  proc SSL_CTX_set_options(ctx: SslCtx, options: clong): clong {.cdecl, dynlib: DLLSSLName, importc.}
  const SSL_OP_NO_RENEGOTIATION = 1073741824
  const SSL_OP_NO_SESSION_RESUMPTION_ON_RENEGOTIATION = 65536

when not defined(ssl):
  type SslError = object of CatchableError

const
  preface = "PRI * HTTP/2.0\r\L\r\LSM\r\L\r\L"
  statusLineLen = ":status: xxx\r\n".len
  maxStreamId = (1'u32 shl 31) - 1'u32
  # https://httpwg.org/specs/rfc9113.html#SettingValues
  stgHeaderTableSize* = 4096'u32
  stgInitialMaxConcurrentStreams* = uint32.high
  stgInitialWindowSize* = (1'u32 shl 16) - 1'u32
  stgMaxWindowSize* = (1'u32 shl 31) - 1'u32
  stgInitialMaxFrameSize* = 1'u32 shl 14
  stgMaxFrameSize* = (1'u32 shl 24) - 1'u32
  stgDisablePush* = 0'u32
const
  stgWindowSize* {.intdefine: "hyperxWindowSize".} = 262_144
  stgServerMaxConcurrentStreams* {.intdefine: "hyperxMaxConcurrentStrms".} = 100
  stgMaxSettingsList* {.intdefine: "hyperxMaxSettingsList".} = 100

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
): cint {.cdecl, raises: [], definedSsl.} =
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
): SslContext {.raises: [HyperxConnError], definedSsl.} =
  # protSSLv23 will disable all protocols
  # lower than the min protocol defined
  # in openssl.config, usually +TLSv1.2
  result = catch newContext(
    protSSLv23,
    verifyMode = CVerifyPeer,
    certFile = certFile,
    keyFile = keyFile
  )
  doAssert result != nil, "failure to initialize the SSL context"
  # https://httpwg.org/specs/rfc9113.html#tls12features
  const ctxOps = SSL_OP_ALL or
    SSL_OP_NO_SSLv2 or
    SSL_OP_NO_SSLv3 or
    SSL_OP_NO_RENEGOTIATION or
    SSL_OP_NO_SESSION_RESUMPTION_ON_RENEGOTIATION
  let ctxOpsSet = SSL_CTX_set_options(result.context, ctxOps)
  doAssert (ctxOpsSet and ctxOps) == ctxOps, "Ssl set options error"
  case clientTyp
  of ctServer:
    # discard should not be needed;
    # it returns void, but nim definition is wrong
    discard SSL_CTX_set_alpn_select_cb(
      result.context, sslContextAlpnSelect, nil
    )
  of ctClient:
    let openSslVersion = uncatch getOpenSSLVersion()
    doAssert openSslVersion >= 0x10002000
    let ctxAlpnSet = SSL_CTX_set_alpn_protos(
      result.context, "\x02h2", 3
    )
    doAssert ctxAlpnSet == 0, "Ssl set alpn protos error"

when defined(hyperxTest):
  type MyAsyncSocket* = TestSocket
else:
  type MyAsyncSocket* = AsyncSocket

when not defined(hyperxTest):
  proc newMySocket*: MyAsyncSocket {.raises: [HyperxConnError].} =
    result = catch newAsyncSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, buffered = true)
    doAssert result != nil

type
  ClientContext* = ref object
    typ: ClientTyp
    sock*: MyAsyncSocket
    hostname*: string
    port: Port
    isConnected*: bool
    isGracefulShutdown: bool
    headersEnc, headersDec: DynHeaders
    streams: Streams
    streamOpenedMsgs*: ValueAsync[Stream]
    currStreamId: StreamId
    peerMaxConcurrentStreams: uint32
    peerWindowSize: uint32
    peerWindow: int32  # can be negative
    peerMaxFrameSize: uint32
    peerWindowUpdateSig: SignalAsync
    windowPending, windowProcessed: int
    windowUpdateSig: SignalAsync
    sendBuff: string
    sendBuffSig, sendBuffDoneSig: SignalAsync
    error*: ref HyperxConnError
    when defined(hyperxStats):
      frmsSent: int
      frmsSentTyp: array[10, int]
      bytesSent: int

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
    isGracefulShutdown: false,
    headersEnc: initDynHeaders(stgHeaderTableSize.int),
    headersDec: initDynHeaders(stgHeaderTableSize.int),
    streams: initStreams(),
    currStreamId: 0.StreamId,
    streamOpenedMsgs: newValueAsync[Stream](),
    peerMaxConcurrentStreams: stgInitialMaxConcurrentStreams,
    peerWindow: stgInitialWindowSize.int32,
    peerWindowSize: stgInitialWindowSize,
    peerMaxFrameSize: stgInitialMaxFrameSize,
    peerWindowUpdateSig: newSignal(),
    windowPending: 0,
    windowProcessed: 0,
    windowUpdateSig: newSignal(),
    sendBuff: "",
    sendBuffSig: newSignal(),
    sendBuffDoneSig: newSignal()
  )

proc close*(client: ClientContext) {.raises: [HyperxConnError].} =
  if not client.isConnected:
    return
  client.isConnected = false
  try:
    catch client.sock.close()
  finally:
    client.streamOpenedMsgs.close()
    client.streams.close()
    client.peerWindowUpdateSig.close()
    client.windowUpdateSig.close()
    client.sendBuffSig.close()
    client.sendBuffDoneSig.close()

func stream(client: ClientContext, sid: StreamId): Stream {.raises: [].} =
  client.streams.get sid

func openMainStream(client: ClientContext): Stream {.raises: [StreamsClosedError].} =
  doAssert frmSidMain notin client.streams
  result = client.streams.open(frmSidMain, client.peerWindowSize.int32)

func maxPeerStreamIdSeen(client: ClientContext): StreamId {.raises: [].} =
  case client.typ
  of ctClient: StreamId 0
  of ctServer: client.currStreamId

when defined(hyperxStats):
  func echoStats*(client: ClientContext) =
    debugEcho(
      "frmSent: ", $client.frmsSent, "\n",
      "frmsSentTyp: ", $client.frmsSentTyp, "\n",
      "bytesSent: ", $client.bytesSent
    )

when defined(hyperxSanityCheck):
  func sanityCheckAfterClose(client: ClientContext) {.raises: [].} =
    doAssert not client.isConnected
    doAssert client.streamOpenedMsgs.isClosed
    doAssert client.peerWindowUpdateSig.isClosed
    doAssert client.windowUpdateSig.isClosed
    doAssert client.windowProcessed >= 0
    doAssert client.windowPending >= 0
    doAssert client.windowPending == client.windowProcessed
    #debugEcho "sanity checked"

func validateHeader(
  ss: string,
  nn, vv: Slice[int]
) {.raises: [HyperxConnError].} =
  # https://www.rfc-editor.org/rfc/rfc9113.html#name-field-validity
  # field validity only because headers and trailers don't have
  # the same validation
  const badNameChars = {
    0x00'u8 .. 0x20'u8,
    0x41'u8 .. 0x5a'u8,
    0x7f'u8 .. 0xff'u8
  }
  check nn.len > 0, newConnError(hyxProtocolError)
  var i = 0
  for ii in nn:
    check ss[ii].uint8 notin badNameChars, newConnError(hyxProtocolError)
    if i > 0:
      check ss[ii] != ':', newConnError(hyxProtocolError)
    inc i
  for ii in vv:
    check ss[ii].uint8 notin {0x00'u8, 0x0a, 0x0d}, newConnError(hyxProtocolError)
  if vv.len > 0:
    check ss[vv.a].uint8 notin {0x20'u8, 0x09}, newConnError(hyxProtocolError)
    check ss[vv.b].uint8 notin {0x20'u8, 0x09}, newConnError(hyxProtocolError)

func hpackDecode(
  client: ClientContext,
  ss: var string,
  payload: openArray[byte]
) {.raises: [HyperxConnError].} =
  var dhSize = -1
  var nn = 0 .. -1
  var vv = 0 .. -1
  var i = 0
  var i2 = -1
  let L = payload.len
  var canResize = true
  try:
    while i < L:
      doAssert i > i2; i2 = i
      i += hdecode(
        toOpenArray(payload, i, L-1),
        client.headersDec, ss, nn, vv, dhSize
      )
      if dhSize > -1:
        check canResize, newConnError(hyxCompressionError)
        check dhSize <= stgHeaderTableSize.int, newConnError(hyxCompressionError)
        client.headersDec.setSize dhSize
      else:
        # note this validate headers and trailers
        validateHeader(ss, nn, vv)
        # can resize multiple times before a header, but not after
        canResize = false
    doAssert i == L
  except HpackError as err:
    debugErr2 err
    raise newConnError(hyxCompressionError, parent=err)

func hpackEncode*(
  client: ClientContext,
  payload: var seq[byte],  # XXX var string
  name, value: openArray[char]
) {.raises: [HyperxConnError].} =
  ## headers must be added synchronously, no await in between,
  ## or else a table resize could occur in the meantime
  try:
    discard hencode(name, value, client.headersEnc, payload, huffman = false)
  except HpackError as err:
    debugErr2 err
    raise newConnError(err.msg, err)

proc sendNaked(client: ClientContext, frm: Frame) {.async.} =
  debugInfo "===SENT==="
  debugInfo $frm
  debugInfo debugPayload(frm)
  doAssert frm.payloadLen.int == frm.payload.len
  doAssert frm.payload.len <= client.peerMaxFrameSize.int
  doAssert frm.sid <= StreamId maxStreamId
  check not client.sock.isClosed, newConnClosedError()
  GC_ref frm
  try:
    await client.sock.send(frm.rawBytesPtr, frm.len)
  finally:
    GC_unref frm
  when defined(hyperxStats):
    client.frmsSent += 1
    client.frmsSentTyp[frm.typ.int] += 1
    client.bytesSent += frm.len

proc sendTaskNaked(client: ClientContext) {.async.} =
  var buff = ""
  while true:
    while client.sendBuff.len == 0:
      await client.sendBuffSig.waitFor()
    buff.setLen 0
    buff.add client.sendBuff
    client.sendBuff.setLen 0
    check not client.sock.isClosed, newConnClosedError()
    await client.sock.send(addr buff[0], buff.len)
    check not client.sendBuffDoneSig.isClosed, newConnClosedError()
    client.sendBuffDoneSig.trigger()

proc sendTask(client: ClientContext) {.async.} =
  try:
    await client.sendTaskNaked()
  except QueueClosedError:
    discard
  except HyperxError, OsError, SslError:
    let err = getCurrentException()
    debugErr2 err
    client.error ?= newConnError(err.msg)
    client.close()
    raise newConnError(err.msg, err)
  finally:
    client.close()

proc send(client: ClientContext, frm: Frame) {.async.} =
  doAssert frm.payloadLen.int == frm.payload.len
  doAssert frm.payload.len <= client.peerMaxFrameSize.int
  doAssert frm.sid <= StreamId maxStreamId
  client.sendBuff.add frm.s
  check not client.sendBuffSig.isClosed, newConnClosedError()
  client.sendBuffSig.trigger()
  # XXX this is right if not currently sending a buff, need to wait again
  #     if currently sending.
  #if frm.typ in {frmtRstStream, frmtGoAway}:
  #  await client.sendBuffDoneSig.waitFor()
  #elif frm.typ in {frmtHeaders, frmtData} and frmfEndStream in frm.flags:
  #  await client.sendBuffDoneSig.waitFor()
  #elif client.sendBuff.len > 8 * 1024:
  #  await client.sendBuffDoneSig.waitFor()
  await client.sendBuffDoneSig.waitFor()

proc sendSilently(client: ClientContext, frm: Frame) {.async.} =
  ## Call this to send within an except
  ## block that's raising an exception.
  debugInfo "frm sent silently"
  doAssert frm.sid == frmSidMain
  doAssert frm.typ == frmtGoAway
  try:
    await client.sendNaked(frm)
  except HyperxError, OsError, SslError:
    debugErr getCurrentException()

func handshakeBlob(typ: ClientTyp): string {.compileTime.} =
  result = ""
  var frmStg = newSettingsFrame()
  case typ
  of ctClient:
    frmStg.addSetting frmsEnablePush, stgDisablePush
  of ctServer:
    frmStg.addSetting(
      frmsMaxConcurrentStreams, stgServerMaxConcurrentStreams.uint32
    )
  doAssert stgWindowSize <= stgMaxWindowSize
  frmStg.addSetting frmsInitialWindowSize, stgWindowSize
  if typ == ctClient:
    result.add preface
  result.add frmStg.s
  if stgWindowSize > stgInitialWindowSize:
    let frmWu = newWindowUpdateFrame(
      frmSidMain, (stgWindowSize-stgInitialWindowSize).int
    )
    result.add frmWu.s

const clientHandshakeBlob = handshakeBlob(ctClient)
const serverHandshakeBlob = handshakeBlob(ctServer)

proc handshakeNaked(client: ClientContext) {.async.} =
  doAssert client.isConnected
  debugInfo "handshake"
  check not client.sock.isClosed, newConnClosedError()
  case client.typ
  of ctClient: await client.sock.send(clientHandshakeBlob)
  of ctServer: await client.sock.send(serverHandshakeBlob)
  if client.typ == ctServer:
    var blob = newString(preface.len)
    check not client.sock.isClosed, newConnClosedError()
    let blobRln = await client.sock.recvInto(addr blob[0], blob.len)
    check blobRln == blob.len, newConnClosedError()
    check blob == preface, newConnError(hyxProtocolError)

proc handshake(client: ClientContext) {.async.} =
  try:
    await client.handshakeNaked()
  except OsError, SslError:
    let err = getCurrentException()
    debugErr2 err
    doAssert client.isConnected
    # XXX err.msg includes a traceback for SslError but it should not
    client.error ?= newConnError(err.msg)
    client.close()
    raise newConnError(err.msg, err)

func doTransitionRecv(
  s: Stream, frm: Frame
) {.raises: [HyperxConnError].} =
  doAssert frm.sid == s.id
  doAssert frm.sid != frmSidMain
  doAssert s.state != strmInvalid
  check frm.typ in frmStreamAllowed, newConnError(hyxProtocolError)
  let nextState = toNextStateRecv(s.state, frm.toStreamEvent)
  if nextState == strmInvalid:
    if s.state == strmHalfClosedRemote:
      # This used to be a strmError, but it was raicy.
      # Since we may send an END_STREAM before
      # this propagates, and we cannot send the RST on a closed stream.
      raise newConnError(hyxStreamClosed)
    if s.state == strmClosed:
      raise newConnError(hyxStreamClosed)
    raise newConnError(hyxProtocolError)
  s.state = nextState

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
    check frm2.sid == frm.sid, newConnError(hyxProtocolError)
    check frm2.typ == frmtContinuation, newConnError(hyxProtocolError)
    check frm2.payloadLen <= stgInitialMaxFrameSize, newConnError(hyxProtocolError)
    check frm2.payloadLen >= 0, newConnError(hyxProtocolError)
    if frm2.payloadLen == 0:
      continue
    # XXX the spec does not limit total headers size,
    #     but there needs to be a limit unless we stream
    let totalPayloadLen = frm2.payloadLen.int + frm.payload.len
    check totalPayloadLen <= stgInitialMaxFrameSize.int, newConnError(hyxProtocolError)
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
  check payloadLen <= stgInitialMaxFrameSize.int, newConnError(hyxFrameSizeError)
  var paddingLen = 0'u8
  if frm.isPadded:
    debugInfo "Padding"
    check payloadLen >= frmPaddingSize, newConnError(hyxProtocolError)
    check not client.sock.isClosed, newConnClosedError()
    let paddingRln = await client.sock.recvInto(addr paddingLen, frmPaddingSize)
    check paddingRln == frmPaddingSize, newConnClosedError()
    payloadLen -= frmPaddingSize
  # prio is deprecated so do nothing with it
  if frm.hasPrio:
    debugInfo "Priority"
    check payloadLen >= frmPrioritySize, newConnError(hyxProtocolError)
    var prio = [0'u8, 0, 0, 0, 0]
    check not client.sock.isClosed, newConnClosedError()
    let prioRln = await client.sock.recvInto(addr prio, prio.len)
    check prioRln == frmPrioritySize, newConnClosedError()
    check prioDependency(prio) != frm.sid, newConnError(hyxProtocolError)
    payloadLen -= frmPrioritySize
  # padding can be equal at this point, because we don't count frmPaddingSize
  check payloadLen >= paddingLen.int, newConnError(hyxProtocolError)
  check isValidSize(frm, payloadLen), newConnError(hyxFrameSizeError)
  if payloadLen > 0:
    frm.grow payloadLen
    check not client.sock.isClosed, newConnClosedError()
    let payloadRln = await client.sock.recvInto(
      frm.rawPayloadBytesPtr, payloadLen
    )
    check payloadRln == payloadLen, newConnClosedError()
    debugInfo frm.debugPayload
  if paddingLen > 0:
    frm.shrink paddingLen.int
  if frmfEndHeaders notin frm.flags and frm.typ in {frmtHeaders, frmtPushPromise}:
    debugInfo "Continuation"
    await client.readUntilEnd(frm)

const connFrmAllowed = {
  frmtSettings,
  frmtPing,
  frmtGoAway,
  frmtWindowUpdate
}

proc mainStreamNaked(client: ClientContext, stream: Stream) {.async.} =
  template flowControlBoundCheck(a, b: untyped): untyped =
    if b < 0 and a > int32.high + b: raise newConnError(hyxFlowControlError)
    if b > 0 and a < int32.low + b: raise newConnError(hyxFlowControlError)
  doAssert stream.id == frmSidMain
  var frm: Frame
  while true:
    frm = await stream.msgs.get()
    stream.msgs.getDone()
    case frm.typ
    of frmtWindowUpdate:
      check frm.windowSizeInc > 0, newConnError(hyxProtocolError)
      check frm.windowSizeInc <= stgMaxWindowSize, newConnError(hyxProtocolError)
      check client.peerWindow <= stgMaxWindowSize.int32 - frm.windowSizeInc.int32,
        newConnError(hyxFlowControlError)
      client.peerWindow += frm.windowSizeInc.int32
      client.peerWindowUpdateSig.trigger()
    of frmtSettings:
      check frm.payloadLen.int <= stgMaxSettingsList * frmSettingsSize,
        newConnError(hyxProtocolError)
      for (setting, value) in frm.settings:
        # https://www.rfc-editor.org/rfc/rfc7541.html#section-4.2
        case setting
        of frmsHeaderTableSize:
          # maybe max table size should be a setting instead of 4096
          client.headersEnc.setSize min(value.int, stgHeaderTableSize.int)
        of frmsEnablePush:
          case client.typ
          of ctClient: check value == 0, newConnError(hyxProtocolError)
          of ctServer: check value == 0 or value == 1, newConnError(hyxProtocolError)
        of frmsMaxConcurrentStreams:
          client.peerMaxConcurrentStreams = value
        of frmsInitialWindowSize:
          check value <= stgMaxWindowSize, newConnError(hyxFlowControlError)
          for strm in values client.streams:
            flowControlBoundCheck(client.peerWindowSize.int32, strm.peerWindow)
            strm.peerWindow = client.peerWindowSize.int32 - strm.peerWindow
            flowControlBoundCheck(value.int32, strm.peerWindow)
            strm.peerWindow = value.int32 - strm.peerWindow
            if not strm.peerWindowUpdateSig.isClosed:
              strm.peerWindowUpdateSig.trigger()
          client.peerWindowSize = value
          if not client.peerWindowUpdateSig.isClosed:
            client.peerWindowUpdateSig.trigger()
        of frmsMaxFrameSize:
          check value >= stgInitialMaxFrameSize, newConnError(hyxProtocolError)
          check value <= stgMaxFrameSize, newConnError(hyxProtocolError)
          client.peerMaxFrameSize = value
        of frmsMaxHeaderListSize:
          # this is only advisory, do nothing for now.
          # server may reply a 431 status (request header fields too large)
          discard
        else:
          # ignore unknown setting
          debugInfo "unknown setting received"
      if frmfAck notin frm.flags:
        await client.send newSettingsFrame(ack = true)
    of frmtPing:
      if frmfAck notin frm.flags:
        await client.send newPingFrame(ackPayload = frm.payload)
      else:
        let sid = frm.pingData().StreamId
        if sid in client.streams:
          let strm = client.streams.get sid
          if not strm.pingSig.isClosed:
            strm.pingSig.trigger()
    of frmtGoAway:
      client.isGracefulShutdown = true
      client.error ?= newConnError(frm.errCode(), hyxRemoteErr)
      # streams are never created by ctServer,
      # so there are no streams to close
      if client.typ == ctClient:
        let sid = frm.lastStreamId()
        for strm in values client.streams:
          if strm.id.uint32 > sid:
            strm.close()
    else:
      doAssert frm.typ notin connFrmAllowed
      raise newConnError(hyxProtocolError)

proc mainStream(client: ClientContext, stream: Stream) {.async.} =
  try:
    await mainStreamNaked(client, stream)
  except QueueClosedError:
    doAssert not client.isConnected
  except HyperxConnError as err:
    debugErr2 err
    client.error ?= newError err
    await client.sendSilently newGoAwayFrame(
      client.maxPeerStreamIdSeen, err.code
    )
    client.close()
    raise err
  except CatchableError as err:
    debugErr2 err
    raise err
  finally:
    client.close()

proc recvDispatcherNaked(client: ClientContext) {.async.} =
  ## Dispatch messages to open streams.
  ## Note decoding headers must be done in message received order,
  ## so it needs to be done here. Same for processing the main
  ## stream messages.
  let mainStrm = client.streams.get frmSidMain
  var headers = ""
  var frm = newFrame()
  while client.isConnected:
    frm.clear()
    await client.read frm
    debugInfo "recv data on stream " & $frm.sid.int
    if frm.typ.isUnknown:
      continue
    # Prio is deprecated and needs to be ignored here
    if frm.typ == frmtPriority:
      check frm.strmDependency != frm.sid, newConnError(hyxProtocolError)
      continue
    if frm.sid == frmSidMain:
      # Settings need to be applied before consuming following messages
      await mainStrm.msgs.put frm
      continue
    check frm.typ in frmStreamAllowed, newConnError(hyxProtocolError)
    check frm.sid.int mod 2 != 0, newConnError(hyxProtocolError)
    if client.typ == ctServer and
        frm.sid > client.currStreamId and
        not client.isGracefulShutdown:
      check client.streams.len <= stgServerMaxConcurrentStreams,
        newConnError(hyxProtocolError)
      client.currStreamId = frm.sid
      # we do not store idle streams, so no need to close them
      let strm = client.streams.open(frm.sid, client.peerWindowSize.int32)
      await client.streamOpenedMsgs.put strm
    if frm.typ == frmtHeaders:
      headers.setLen 0
      client.hpackDecode(headers, frm.payload)
      frm.shrink frm.payload.len
      frm.s.add headers
    if frm.typ == frmtData and frm.payloadLen.int > 0:
      check client.windowPending <= stgWindowSize.int - frm.payloadLen.int,
        newConnError(hyxFlowControlError)
      client.windowPending += frm.payloadLen.int
    if frm.typ == frmtWindowUpdate:
      check frm.windowSizeInc > 0, newConnError(hyxProtocolError)
    # Process headers even if the stream does not exist
    if frm.sid notin client.streams:
      if frm.typ == frmtData:
        client.windowProcessed += frm.payloadLen.int
        if client.windowProcessed > stgWindowSize.int div 2:
          client.windowUpdateSig.trigger()
      if client.typ == ctServer and
          frm.sid > client.currStreamId:
        doAssert client.isGracefulShutdown
        await client.send newGoAwayFrame(
          client.maxPeerStreamIdSeen, frmeNoError
        )
      else:
        check frm.typ in {frmtRstStream, frmtWindowUpdate},
          newConnError hyxStreamClosed
      debugInfo "stream not found " & $frm.sid.int
      continue
    var stream = client.streams.get frm.sid
    if frm.typ == frmtData:
      check stream.windowPending <= stgWindowSize.int - frm.payloadLen.int,
        newConnError(hyxFlowControlError)
      stream.windowPending += frm.payloadLen.int
    try:
      await stream.msgs.put frm
    except QueueClosedError:
      check frm.typ in {frmtRstStream, frmtWindowUpdate},
        newConnError hyxStreamClosed
      debugInfo "stream is closed " & $frm.sid.int

proc recvDispatcher(client: ClientContext) {.async.} =
  # XXX always store error for all errors
  #     everywhere where queues are closed
  try:
    await client.recvDispatcherNaked()
  except QueueClosedError:
    doAssert not client.isConnected
  except HyperxConnError as err:
    debugErr2 err
    client.error ?= newError err
    await client.sendSilently newGoAwayFrame(
      client.maxPeerStreamIdSeen, err.code
    )
    client.close()
    raise err
  except HyperxStrmError:
    debugErr getCurrentException()
    doAssert false
  except OsError, SslError:
    let err = getCurrentException()
    debugErr2 err
    client.error ?= newConnError(err.msg)
    raise newConnError(err.msg, err)
  except CatchableError as err:
    debugErr2 err
    raise err
  finally:
    debugInfo "responseDispatcher exited"
    client.close()

proc windowUpdateTaskNaked(client: ClientContext) {.async.} =
  while client.isConnected:
    while client.windowProcessed <= stgWindowSize.int div 2:
      await client.windowUpdateSig.waitFor()
    doAssert client.windowProcessed > 0
    doAssert client.windowPending >= client.windowProcessed
    client.windowPending -= client.windowProcessed
    let oldWindow = client.windowProcessed
    client.windowProcessed = 0
    await client.send newWindowUpdateFrame(frmSidMain, oldWindow)

proc windowUpdateTask(client: ClientContext) {.async.} =
  try:
    await client.windowUpdateTaskNaked()
  except QueueClosedError:
    doAssert not client.isConnected
  except HyperxConnError as err:
    debugErr2 err
    client.error ?= newError err
    raise err
  except CatchableError as err:
    debugErr2 err
    raise err
  finally:
    debugInfo "windowUpdateTask exited"
    client.close()

proc connect(client: ClientContext) {.async.} =
  catch await client.sock.connect(client.hostname, client.port)

proc failSilently(f: Future[void]) {.async.} =
  ## Be careful when wrapping non {.async.} procs,
  ## as they may raise before the wrap
  if f == nil:
    return
  try:
    await f
  except HyperxError:
    debugErr getCurrentException()

template with*(client: ClientContext, body: untyped): untyped =
  discard getGlobalDispatcher()  # setup event loop
  doAssert not client.isConnected
  var dispFut, winupFut, mainStreamFut, sendTaskFut: Future[void] = nil
  try:
    client.isConnected = true
    if client.typ == ctClient:
      await client.connect()
    await client.handshake()
    sendTaskFut = client.sendTask()
    mainStreamFut = client.mainStream(client.openMainStream())
    winupFut = client.windowUpdateTask()
    dispFut = client.recvDispatcher()
    block:
      body
  # do not handle any error here
  finally:
    # XXX do gracefull shutdown with timeout,
    #     wait for send/recv to drain the queue
    #     before closing
    client.close()
    # do not bother the user with hyperx errors
    # at this point body completed or errored out
    await failSilently(dispFut)
    await failSilently(winupFut)
    await failSilently(mainStreamFut)
    await failSilently(sendTaskFut)
    when defined(hyperxSanityCheck):
      client.sanityCheckAfterClose()

type
  ClientStreamState* = enum
    csStateInitial,
    csStateOpened,
    csStateHeaders,
    csStateData,
    csStateEnded
  ClientStream* = ref object
    client*: ClientContext
    stream*: Stream
    stateRecv, stateSend: ClientStreamState
    contentLen, contentLenRecv: int64
    headersRecv, bodyRecv, trailersRecv: string
    headersRecvSig, bodyRecvSig: SignalAsync
    bodyRecvLen: int
    frm: Frame

func newClientStream*(client: ClientContext, stream: Stream): ClientStream =
  ClientStream(
    client: client,
    stream: stream,
    stateRecv: csStateInitial,
    stateSend: csStateInitial,
    contentLen: 0,
    contentLenRecv: 0,
    bodyRecv: "",
    bodyRecvSig: newSignal(),
    bodyRecvLen: 0,
    headersRecv: "",
    headersRecvSig: newSignal(),
    trailersRecv: "",
    frm: newEmptyFrame()
  )

func newClientStream*(client: ClientContext): ClientStream =
  doAssert client.typ == ctClient
  check not client.isGracefulShutdown, newGracefulShutdownError()
  let stream = client.streams.dummy()
  newClientStream(client, stream)

proc close(strm: ClientStream) {.raises: [].} =
  strm.stream.close()
  strm.client.streams.close(strm.stream.id)
  strm.bodyRecvSig.close()
  strm.headersRecvSig.close()
  try:
    strm.client.peerWindowUpdateSig.trigger()
  except SignalClosedError:
    discard

func openStream(strm: ClientStream) {.raises: [StreamsClosedError, GracefulShutdownError].} =
  # XXX some error if max sid is reached
  # XXX error if maxStreams is reached
  template client: untyped = strm.client
  doAssert client.typ == ctClient
  check not client.isGracefulShutdown, newGracefulShutdownError()
  var sid = client.currStreamId
  sid += (if sid == StreamId 0: StreamId 1 else: StreamId 2)
  client.streams.open(strm.stream, sid, client.peerWindowSize.int32)
  client.currStreamId = sid

func recvEnded*(strm: ClientStream): bool {.raises: [].} =
  strm.stateRecv == csStateEnded and
  strm.headersRecv.len == 0 and
  strm.bodyRecv.len == 0

func sendEnded*(strm: ClientStream): bool {.raises: [].} =
  strm.stateSend == csStateEnded

proc windowEnd(strm: ClientStream) {.raises: [].} =
  template client: untyped = strm.client
  template stream: untyped = strm.stream
  # XXX strm.isClosed
  doAssert strm.bodyRecvSig.isClosed
  doAssert stream.windowPending >= stream.windowProcessed
  client.windowProcessed += stream.windowPending - stream.windowProcessed
  try:
    if client.windowProcessed > stgWindowSize.int div 2:
      client.windowUpdateSig.trigger()
  except SignalClosedError:
    doAssert not client.isConnected

func validateHeaders(s: openArray[byte], typ: ClientTyp) {.raises: [HyperxStrmError].} =
  case typ
  of ctServer: serverHeadersValidation(s)
  of ctClient: clientHeadersValidation(s)

func doTransitionSend(s: Stream, frm: Frame) {.raises: [].} =
  # we cannot raise stream errors here because of
  # hpack state the frame needs to be sent or close the conn;
  # could raise stream errors for typ != header
  doAssert frm.sid == s.id
  doAssert frm.sid != frmSidMain
  doAssert s.state != strmInvalid
  if frm.typ == frmtContinuation:
    return
  doAssert frm.typ in frmStreamAllowed
  let nextState = toNextStateSend(s.state, frm.toStreamEvent)
  doAssert nextState != strmInvalid  #, $frm
  s.state = nextState

proc write(strm: ClientStream, frm: Frame): Future[void] =
  template client: untyped = strm.client
  template stream: untyped = strm.stream
  # This is done in the next headers after settings ACK put
  if frm.typ == frmtHeaders and client.headersEnc.hasResized():
    # XXX handle padding and prio
    doAssert not frm.isPadded
    doAssert not frm.hasPrio
    # XXX avoid copy?
    var payload = newSeq[byte]()
    client.headersEnc.encodeLastResize(payload)
    client.headersEnc.clearLastResize()
    payload.add frm.payload
    frm.shrink frm.payload.len
    frm.add payload
  stream.doTransitionSend frm
  result = client.send frm

proc process(stream: Stream, frm: Frame) {.raises: [HyperxConnError, HyperxStrmError, QueueClosedError].} =
  doAssert stream.id == frm.sid
  doAssert frm.typ in frmStreamAllowed
  stream.doTransitionRecv frm
  case frm.typ
  of frmtRstStream:
    stream.error = newStrmError(frm.errCode, hyxRemoteErr)
    stream.close()
    raise newStrmError(frm.errCode, hyxRemoteErr)
  of frmtWindowUpdate:
    check frm.windowSizeInc > 0, newStrmError hyxProtocolError
    check frm.windowSizeInc <= stgMaxWindowSize, newStrmError hyxProtocolError
    check stream.peerWindow <= stgMaxWindowSize.int32 - frm.windowSizeInc.int32,
      newStrmError hyxFlowControlError
    stream.peerWindow += frm.windowSizeInc.int32
    if not stream.peerWindowUpdateSig.isClosed:
      stream.peerWindowUpdateSig.trigger()
  else:
    doAssert frm.typ in {frmtData, frmtHeaders}

# this needs to be {.async.} to fail-silently
proc writeRst(strm: ClientStream, code: FrmErrCode) {.async.} =
  template stream: untyped = strm.stream
  check stream.state in strmStateRstSendAllowed,
    newStrmError hyxStreamClosed
  strm.stateSend = csStateEnded
  await strm.write newRstStreamFrame(stream.id, code)

proc recvHeadersTaskNaked(strm: ClientStream) {.async.} =
  template stream: untyped = strm.stream
  doAssert strm.stateRecv == csStateOpened
  strm.stateRecv = csStateHeaders
  # https://httpwg.org/specs/rfc9113.html#HttpFraming
  var frm: Frame
  while true:
    while true:
      frm = await stream.msgs.get()
      stream.msgs.getDone()
      stream.process(frm)
      if frm.typ in {frmtHeaders, frmtData}:
        break
    check frm.typ == frmtHeaders, newStrmError hyxProtocolError
    validateHeaders(frm.payload, strm.client.typ)
    if strm.client.typ == ctServer:
      break
    check frm.payload.len >= statusLineLen, newStrmError hyxProtocolError
    if frm.payload[9] == '1'.byte:
      check frmfEndStream notin frm.flags, newStrmError(hyxProtocolError)
    else:
      break
  strm.headersRecv.add frm.payload
  try:
    strm.contentLen = contentLen(frm.payload)
  except ValueError as err:
    debugErr2 err
    raise newStrmError(hyxProtocolError, parent=err)
  if frmfEndStream in frm.flags:
    # XXX dont do for no content status 1xx/204/304 and HEAD response
    if strm.client.typ == ctServer:
      check strm.contentLen <= 0, newStrmError(hyxProtocolError)
    strm.stateRecv = csStateEnded
  strm.headersRecvSig.trigger()
  strm.headersRecvSig.close()

func contentLenCheck(strm: ClientStream) {.raises: [HyperxStrmError].} =
  check(
    strm.contentLen == -1 or strm.contentLen == strm.contentLenRecv,
    newStrmError(hyxProtocolError)
  )

proc recvBodyTaskNaked(strm: ClientStream) {.async.} =
  template stream: untyped = strm.stream
  doAssert strm.stateRecv in {csStateHeaders, csStateData}
  strm.stateRecv = csStateData
  var frm: Frame
  while true:
    while true:
      frm = await stream.msgs.get()
      stream.msgs.getDone()
      stream.process(frm)
      if frm.typ in {frmtHeaders, frmtData}:
        break
    # https://www.rfc-editor.org/rfc/rfc9110.html#section-6.5
    if frm.typ == frmtHeaders:
      strm.trailersRecv.add frm.payload
      check frmfEndStream in frm.flags, newStrmError(hyxProtocolError)
      if strm.client.typ == ctServer:
        strm.contentLenCheck()
      validateTrailers(frm.payload)
      strm.stateRecv = csStateEnded
      break
    check frm.typ == frmtData, newStrmError(hyxProtocolError)
    strm.bodyRecv.add frm.payload
    strm.bodyRecvLen += frm.payloadLen.int
    strm.contentLenRecv += frm.payload.len
    if frmfEndStream in frm.flags:
      # XXX dont do for no content status 1xx/204/304 and HEAD response
      #     they could send empty data to close the stream so this is called
      if strm.client.typ == ctServer:
        strm.contentLenCheck()
      strm.stateRecv = csStateEnded
      break
    strm.bodyRecvSig.trigger()
  strm.bodyRecvSig.trigger()
  strm.bodyRecvSig.close()

proc process(stream: Stream) {.async.} =
  var frm: Frame
  while true:
    frm = await stream.msgs.get()
    stream.msgs.getDone()
    stream.process(frm)

proc recvTask(strm: ClientStream) {.async.} =
  template client: untyped = strm.client
  template stream: untyped = strm.stream
  try:
    await recvHeadersTaskNaked(strm)
    if strm.stateRecv != csStateEnded:
      await recvBodyTaskNaked(strm)
    await stream.process()
  except QueueClosedError:
    discard
  except HyperxConnError as err:
    debugErr2 err
    client.error ?= newError err
    await client.sendSilently newGoAwayFrame(
      client.maxPeerStreamIdSeen, err.code
    )
    client.close()
    raise err
  except HyperxStrmError as err:
    debugErr2 err
    stream.error = newError err
    if err.typ == hyxLocalErr:
      await failSilently strm.writeRst(err.code)
    raise err
  except CatchableError as err:
    debugErr2 err
    raise err
  finally:
    strm.close()

proc recvHeadersNaked(strm: ClientStream, data: ref string) {.async.} =
  if strm.stateRecv != csStateEnded and strm.headersRecv.len == 0:
    await strm.headersRecvSig.waitFor()
  data[].add strm.headersRecv
  strm.headersRecv.setLen 0

proc recvHeaders*(strm: ClientStream, data: ref string) {.async.} =
  try:
    await recvHeadersNaked(strm, data)
  except QueueClosedError as err:
    debugErr2 err
    if strm.client.error != nil:
      raise newError(strm.client.error, err)
    if strm.stream.error != nil:
      raise newError(strm.stream.error, err)
    raise err

proc recvBodyNaked(strm: ClientStream, data: ref string) {.async.} =
  template client: untyped = strm.client
  template stream: untyped = strm.stream
  if strm.stateRecv != csStateEnded and strm.bodyRecv.len == 0:
    await strm.bodyRecvSig.waitFor()
  let bodyL = strm.bodyRecvLen
  data[].add strm.bodyRecv
  strm.bodyRecv.setLen 0
  strm.bodyRecvLen = 0
  #if not client.isConnected:
  #  # this avoids raising when sending a window update
  #  # if the conn is closed. Unsure if it's useful
  #  return
  client.windowProcessed += bodyL
  stream.windowProcessed += bodyL
  doAssert stream.windowPending >= stream.windowProcessed
  doAssert client.windowPending >= client.windowProcessed
  if client.windowProcessed > stgWindowSize.int div 2:
    client.windowUpdateSig.trigger()
  if stream.state in strmStateWindowSendAllowed and
      stream.windowProcessed > stgWindowSize.int div 2:
    stream.windowPending -= stream.windowProcessed
    let oldWindow = stream.windowProcessed
    stream.windowProcessed = 0
    await strm.write newWindowUpdateFrame(stream.id, oldWindow)

proc recvBody*(strm: ClientStream, data: ref string) {.async.} =
  try:
    await recvBodyNaked(strm, data)
  except QueueClosedError as err:
    debugErr2 err
    if strm.client.error != nil:
      raise newError(strm.client.error, err)
    if strm.stream.error != nil:
      raise newError(strm.stream.error, err)
    raise err

func recvTrailers*(strm: ClientStream): string =
  result = strm.trailersRecv

proc sendHeadersImpl*(
  strm: ClientStream,
  headers: seq[byte],
  finish: bool
): Future[void] =
  ## Headers must be HPACK encoded;
  ## headers may be trailers
  template frm: untyped = strm.frm
  doAssert strm.stream.state in strmStateHeaderSendAllowed
  doAssert strm.stateSend == csStateOpened or
    (strm.stateSend in {csStateHeaders, csStateData} and finish)
  if strm.stream.state == strmIdle:
    strm.openStream()
  strm.stateSend = csStateHeaders
  frm.clear()
  frm.add headers
  frm.setTyp frmtHeaders
  frm.setSid strm.stream.id
  frm.setPayloadLen frm.payload.len.FrmPayloadLen
  frm.flags.incl frmfEndHeaders
  if finish:
    frm.flags.incl frmfEndStream
    strm.stateSend = csStateEnded
  result = strm.write frm

proc sendHeaders*(
  strm: ClientStream,
  headers: seq[(string, string)],
  finish: bool
): Future[void] =
  template client: untyped = strm.client
  template stream: untyped = strm.stream
  check stream.state in strmStateHeaderSendAllowed,
    newErrorOrDefault(stream.error, newStrmError hyxStreamClosed)
  var henc = newSeq[byte]()
  for (n, v) in headers:
    client.hpackEncode(henc, n, v)
  result = strm.sendHeadersImpl(henc, finish)

proc sendBodyNaked(
  strm: ClientStream,
  data: ref string,
  finish = false
) {.async.} =
  template client: untyped = strm.client
  template stream: untyped = strm.stream
  template frm: untyped = strm.frm
  check stream.state in strmStateDataSendAllowed,
    newErrorOrDefault(stream.error, newStrmError hyxStreamClosed)
  doAssert strm.stateSend in {csStateHeaders, csStateData}
  strm.stateSend = csStateData
  var dataIdxA = 0
  var dataIdxB = 0
  let L = data[].len
  while dataIdxA <= L:
    while stream.peerWindow <= 0 or client.peerWindow <= 0:
      while stream.peerWindow <= 0:
        await stream.peerWindowUpdateSig.waitFor()
      while client.peerWindow <= 0:
        check stream.state in strmStateDataSendAllowed,
          newErrorOrDefault(stream.error, newStrmError hyxStreamClosed)
        await client.peerWindowUpdateSig.waitFor()
    let peerWindow = min(client.peerWindow, stream.peerWindow)
    dataIdxB = min(dataIdxA+min(peerWindow, stgInitialMaxFrameSize.int), L)
    frm.clear()
    frm.setTyp frmtData
    frm.setSid stream.id
    frm.setPayloadLen (dataIdxB-dataIdxA).FrmPayloadLen
    if finish and dataIdxB == L:
      frm.flags.incl frmfEndStream
      strm.stateSend = csStateEnded
    frm.s.add toOpenArray(data[], dataIdxA, dataIdxB-1)
    stream.peerWindow -= frm.payloadLen.int32
    client.peerWindow -= frm.payloadLen.int32
    check stream.state in strmStateDataSendAllowed,
      newErrorOrDefault(stream.error, newStrmError hyxStreamClosed)
    await strm.write frm
    dataIdxA = dataIdxB
    # allow sending empty data frame
    if dataIdxA == L:
      break

proc sendBody*(
  strm: ClientStream,
  data: ref string,
  finish = false
) {.async.} =
  try:
    await sendBodyNaked(strm, data, finish)
  except QueueClosedError as err:
    debugErr2 err
    if strm.client.error != nil:
      raise newError(strm.client.error, err)
    if strm.stream.error != nil:
      raise newError(strm.stream.error, err)
    raise err

template with*(strm: ClientStream, body: untyped): untyped =
  doAssert strm.stateRecv == csStateInitial
  doAssert strm.stateSend == csStateInitial
  strm.stateRecv = csStateOpened
  strm.stateSend = csStateOpened
  var recvFut: Future[void] = nil
  try:
    recvFut = recvTask(strm)
    block:
      body
    doAssert strm.stream.state == strmClosed
    when defined(hyperxSanityCheck):
      doAssert strm.stateRecv == csStateEnded
      doAssert strm.stateSend == csStateEnded
  finally:
    strm.close()
    strm.windowEnd()
    await failSilently(recvFut)

proc ping(client: ClientContext, strm: Stream) {.async.} =
  # this is done for rst and go-away pings; only one stream ping
  # will ever be in progress
  doAssert strm.id in client.streams
  if strm.pingSig.len > 0:
    await strm.pingSig.waitFor()
  else:
    let sig = strm.pingSig.waitFor()
    await client.send newPingFrame(strm.id.uint32)
    await sig

proc ping(strm: ClientStream) {.async.} =
  await strm.client.ping(strm.stream)

proc cancel*(strm: ClientStream, code: HyperxErrCode) {.async.} =
  ## This may never return until the stream/conn is closed.
  ## This can be called multiple times concurrently,
  ## and it will wait for the cancelation
  # fail silently because if it fails, it closes
  # the stream anyway
  try:
    await failSilently strm.writeRst(code)
    if strm.stream.state == strmClosedRst:
      await failSilently strm.ping()
  finally:
    strm.stream.error ?= newStrmError(hyxStreamClosed)
    strm.close()

proc gracefulClose*(client: ClientContext) {.async.} =
  # returning early is ok
  if client.isGracefulShutdown:
    return
  # fail silently because it's best effort,
  # setting isGracefulShutdown is the only important thing
  await failSilently client.send newGoAwayFrame(
    int32.high.FrmSid, frmeNoError
  )
  await failSilently client.ping client.streams.get(StreamId 0)
  client.isGracefulShutdown = true
  await failSilently client.send newGoAwayFrame(
    client.maxPeerStreamIdSeen, frmeNoError
  )

proc isGracefulClose*(client: ClientContext): bool {.raises: [].} =
  result = client.isGracefulShutdown

when defined(hyperxTest):
  proc putRecvTestData*(client: ClientContext, data: seq[byte]) {.async.} =
    await client.sock.putRecvData data

  proc sentTestData*(client: ClientContext, size: int): Future[seq[byte]] {.async.}  =
    result = newSeq[byte](size)
    let sz = await client.sock.sentInto(addr result[0], size)
    result.setLen sz

when isMainModule:
  block default_settings:
    doAssert stgHeaderTableSize == 4096'u32
    doAssert stgInitialMaxConcurrentStreams == uint32.high
    doAssert stgInitialWindowSize == 65_535'u32
    doAssert stgMaxWindowSize == 2_147_483_647'u32
    doAssert stgInitialMaxFrameSize == 16_384'u32
    doAssert stgMaxFrameSize == 16_777_215'u32
    doAssert stgDisablePush == 0'u32

  echo "ok"
