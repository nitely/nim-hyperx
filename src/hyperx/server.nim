## HTTP/2 server
## WIP

when not defined(ssl):
  {.error: "this lib needs -d:ssl".}

import std/asyncdispatch
import std/asyncnet
import std/openssl
import std/net

import ./clientserver
import ./frame
import ./stream
import ./queue
import ./errors

when defined(hyperxTest):
  import ./testsocket

export
  withClient,
  withStream,
  recvHeaders,
  recvBody,
  sendBody,
  recvEnded,
  ClientStream,
  newClientStream,
  ClientContext

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
  while i+h2AlpnL-1 < inlen.int:
    if h2Alpn == toOpenArray(inProto, i, i+h2AlpnL-1):
      outProto[] = cast[cstring](addr inProto[i+1])
      cast[ptr char](outlen)[] = inProto[i]
      return SSL_TLSEXT_ERR_OK
    i += inProto[i].int + 1
  return SSL_TLSEXT_ERR_NOACK

proc defaultSslContext(
  certFile, keyFile: string
): SslContext {.raises: [InternalSslError].} =
  if not sslContext.isNil:
    return sslContext
  try:
    sslContext = newContext(
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

when not defined(hyperxTest):
  proc newMySocket(
    certFile = "",
    keyFile = ""
  ): MyAsyncSocket {.raises: [InternalOsError].} =
    try:
      result = newAsyncSocket()
      wrapSocket(defaultSslContext(certFile, keyFile), result)
    except CatchableError as err:
      raise newInternalOsError(err.msg)

type
  ServerContext* = ref object
    sock: MyAsyncSocket
    hostname: string
    port: Port
    isConnected: bool

proc newServer*(
  hostname: string,
  port: Port,
  sslCertFile = "",
  sslKeyFile = ""
): ServerContext =
  ServerContext(
    sock: newMySocket(
      certFile = sslCertFile,
      keyFile = sslKeyFile
    ),
    hostname: hostname,
    port: port,
    isConnected: false
  )

proc close(server: ServerContext) =
  if not server.isConnected:
    return
  server.sock.close()
  server.isConnected = false

proc listen(server: ServerContext) =
  server.sock.setSockOpt(OptReuseAddr, true)
  server.sock.bindAddr server.port
  server.sock.listen()

# XXX dont allow receive push promise

proc recvClient*(server: ServerContext): Future[ClientContext] {.async.} =
  # XXX limit number of active clients
  let sock = await server.sock.accept()
  doAssert not sslContext.isNil
  wrapConnectedSocket(
    sslContext, sock, handshakeAsServer, server.hostname
  )
  result = newClient(ctServer, sock, server.hostname)

template withServer*(server: ServerContext, body: untyped): untyped =
  try:
    server.isConnected = true
    server.listen()
    block:
      body
  finally:
    server.close()

proc recvStream*(client: ClientContext): Future[ClientStream] {.async.} =
  let sid = await client.streamOpenedMsgs.pop()
  result = newClientStream(client, sid)

# XXX remove
proc sendHeaders*(
  strm: ClientStream,
  status: int,
  contentType = "",
  contentLen = -1
) {.async.} =
  template client: untyped = strm.client
  doAssert strm.state == csStateRecvEnded
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
