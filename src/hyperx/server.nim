## HTTP/2 server
## WIP

{.define: ssl.}

from std/openssl import
  DLLSSLName,
  SSL_CTX_set_alpn_select_cb,
  SSL_TLSEXT_ERR_NOACK,
  SSL_TLSEXT_ERR_OK,
  SSL_OP_ALL,
  SSL_OP_NO_SSLv2,
  SSL_OP_NO_SSLv3

import ./clientserver
import ./frame
import ./stream
import ./queue
import ./errors

var sslContext {.threadvar.}: SslContext

proc destroySslContext() {.noconv.} =
  sslContext.destroyContext()

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
  while i+h2AlpnL-1 < inlen:
    if h2SslAlpn == toOpenArray(inProto, i, i+h2AlpnL-1):
      outProto[] = addr inProto[i+1]
      cast[ptr char](outlen)[] = inProto[i]
      return SSL_TLSEXT_ERR_OK
    i += inProto[i].int + 1
  return SSL_TLSEXT_ERR_NOACK

proc SSL_CTX_set_options(ctx: SslCtx, options: clong): clong {.cdecl, dynlib: DLLSSLName, importc.}
const SSL_OP_NO_RENEGOTIATION = 1073741824
const SSL_OP_NO_SESSION_RESUMPTION_ON_RENEGOTIATION = 65536

proc defaultSslContext(): SslContext {.raises: [InternalSslError].} =
  if not sslContext.isNil:
    return sslContext
  try:
    sslContext = newContext(protSSLv23, verifyMode=CVerifyNone)
  except CatchableError as err:
    raise newException(InternalSslError, err.msg)
  except Defect as err:
    raise err
  except Exception as err:
    raise newException(Defect, err.msg)
  doAssert sslContext != nil, "failure to initialize the SSL context"
  # https://httpwg.org/specs/rfc9113.html#tls12features
  discard SSL_CTX_set_options(
    sslContext.context,
    SSL_OP_ALL or SSL_OP_NO_SSLv2 or SSL_OP_NO_SSLv3 or
    SSL_OP_NO_RENEGOTIATION or
    SSL_OP_NO_SESSION_RESUMPTION_ON_RENEGOTIATION
  )
  discard SSL_CTX_set_alpn_select_cb(
    sslContext.context, sslContextAlpnSelect, nil
  )
  addQuitProc(destroySslContext)
  return sslContext

proc newMySocket(): MyAsyncSocket {.raises: [InternalOsError].} =
  try:
    result = newAsyncSocket()
    wrapSocket(defaultSslContext(), result)
  except CatchableError as err:
    raise newInternalOsError(err.msg)

type
  ServerContext* = ref object
    sock: MyAsyncSocket
    hostname: string
    port: Port
    isConnected: bool

func newServer(hostname: string, port: Port): ServerContext =
  ServerContext(
    sock: newMySocket(),
    hostname: hostname,
    port: port,
    isConnected: false
  )

func listen(server: ServerContext) =
  server.sock.setSockOpt(OptReuseAddr, true)
  server.sock.bindAddr server.port
  server.sock.listen()

# XXX dont allow receive push promise

proc processClient(
  sock: MyAsyncSocket,
  hostname: string  # ref
) {.async.} =
  let client = newClient(sock, hostname)
  client.isConnected = true
  client.handshake()
  var sendFut = client.sendTask()
  var recvFut = client.recvTask()
  var dispFut = client.recvDispatcher()
  await (sendFut and recvFut and dispFut)

proc serve(server: ServerContext) {.async.} =
  server.listen()
  server.isConnected = true
  while server.isConnected:
    let sock = await server.accept()
    # XXX limit number of peer tasks
    asyncCheck processClient(sock)

proc recvStream(client: ClientContext): Future[ClientStream] {.async.} =
  let sid = await client.strmCreatedEvents.pop()
  result = newClientStream(client, sid)

proc recvHeaders(strm: ClientStream, data: ref string) {.async.} =
  let frm = await strm.client.read(strm.sid)
  check frm.typ == frmtHeaders, newStrmError(errProtocolError)
  data[].add frm.payload
  if frmfEndStream in frm.flags:
    strm.state = csStateRecvEnded

proc sendHeaders*(
  strm: ClientStream,
  status: int,
  contentType = "",
  contentLen = -1
) {.async.} =
  template client: untyped = strm.client
  doAssert strm.state == csStateOpened
  strm.state = csStateSentHeaders
  var frm = newFrame()
  client.addHeader(frm, ":status", $status)
  if contentType.len > 0:
    client.addHeader(frm, "content-type", contentType)
  if contentLen > -1:
    client.addHeader(frm, "content-length", $contentLen)
  frm.setTyp frmtHeaders
  frm.setSid strm.sid.FrmSid
  frm.setPayloadLen frm.payloadSize.FrmPayloadLen
  frm.flags.incl frmfEndHeaders
  if contentLen <= 0:
    frm.flags.incl frmfEndStream
    strm.state = csStateSentEnded
  await client.write frm

when false:
  let server = newServer("foobar.com", Port 443)
  withServer server:
    while server.isConnected:
      let client = await server.recvClient()
      withClient client:
        while client.isConnected:
          let strm = await client.recvStream()
          withStream strm:
            let data = newStringref()
            await strm.recvHeaders(data)
            await strm.recvBody(data)
            # process
            await strm.sendHeaders(data)
            await strm.sendBody(data)
