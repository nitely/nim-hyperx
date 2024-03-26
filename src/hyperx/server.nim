## HTTP/2 server
## WIP

{.define: ssl.}

from std/openssl import 
  SSL_CTX_set_alpn_select_cb,
  SSL_TLSEXT_ERR_NOACK,
  SSL_TLSEXT_ERR_OK

import ./frame
import ./stream
import ./queue
import ./errors

var sslContext {.threadvar.}: SslContext

proc destroySslContext() {.noconv.} =
  sslContext.destroyContext()

proc sslContextCallback(
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
  discard SSL_CTX_set_alpn_select_cb(
    sslContext.context, sslContextCallback, nil
  )
  addQuitProc(destroySslContext)
  return sslContext

type
  MyAsyncSocket = AsyncSocket

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

func newServerContext(
  hostname: string,
  port = Port 443
): ServerContext =
  ServerContext(
    sock: newMySocket(),
    hostname: hostname,
    port: port
  )

type
  ClientContext = ref object
    sock: MyAsyncSocket
    hostname: string
    isConnected: bool
    headersEnc, headersDec: DynHeaders
    streams: Streams
    sendMsgs, recvMsgs: QueueAsync[Frame]

func newClientContext(
  sock: MyAsyncSocket,
  hostname: string
): ClientContext =
  ClientContext(
    sock: sock,
    hostname: hostname,
    isConnected: true,
    headersEnc: initDynHeaders(4096),
    headersDec: initDynHeaders(4096),
    streams: initStreams(),
    recvMsgs: newQueue[Frame](10),
    sendMsgs: newQueue[Frame](10),
  )

func listen(server: ServerContext) =
  server.sock.setSockOpt(OptReuseAddr, true)
  server.sock.bindAddr server.port
  server.sock.listen()

proc processPeer(
  sock: MyAsyncSocket,
  hostname: string  # ref
) {.async.} =
  let client = newClientContext(sock, hostname)
  var sendFut = client.sendTask()
  var recvFut = client.recvTask()
  var reqFut = client.requestDispatcher()
  await (sendFut and recvFut and reqFut)

proc serve(server: ServerContext) {.async.} =
  server.listen()
  server.isConnected = true
  while server.isConnected:
    let sock = await server.accept()
    # XXX limit number of peer tasks
    asyncCheck processPeer(sock)
