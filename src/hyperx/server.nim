## HTTP/2 server
## WIP

when not defined(ssl):
  {.error: "this lib needs -d:ssl".}

import std/asyncdispatch
import std/asyncnet
import std/exitprocs
import std/net

import ./clientserver
import ./stream
import ./queue
import ./errors
import ./utils
import ./asyncsock

when defined(hyperxTest):
  import ./testsocket

export
  withClient,
  withStream,
  recvHeaders,
  recvBody,
  #sendHeaders,
  sendBody,
  recvEnded,
  ClientStream,
  newClientStream,
  ClientContext,
  HyperxConnError,
  HyperxStrmError,
  HyperxError

var sslContext {.threadvar.}: SslContext

proc destroySslContext() {.noconv.} =
  sslContext.destroyContext()

proc defaultSslContext(
  certFile, keyFile: string
): SslContext {.raises: [HyperxConnError].} =
  if not sslContext.isNil:
    return sslContext
  sslContext = defaultSslContext(ctServer, certFile, keyFile)
  addExitProc(destroySslContext)
  return sslContext

when not defined(hyperxTest):
  proc newMySocket(
    certFile = "",
    keyFile = ""
  ): MyAsyncSocket {.raises: [HyperxConnError].} =
    try:
      result = newAsyncSock()
      wrapSocket(defaultSslContext(certFile, keyFile), result)
    except CatchableError as err:
      raise newHyperxConnError(err.msg)

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
  server.sock.setSockOpt(OptReusePort, true)
  server.sock.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)
  server.sock.bindAddr server.port
  server.sock.listen()

# XXX dont allow receive push promise

# XXX limit number of active clients
proc recvClient*(server: ServerContext): Future[ClientContext] {.async.} =
  # note OptNoDelay is inherited from server.sock
  let sock = await server.sock.accept()
  when not defined(hyperxTest):
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
  try:
    let strm = await client.streamOpenedMsgs.pop()
    result = newClientStream(client, strm)
  except QueueClosedError as err:
    doAssert not client.isConnected
    if client.error != nil:
      # https://github.com/nim-lang/Nim/issues/15182
      debugInfo client.error.getStackTrace()
      raise newHyperxConnError(client.error.msg)
    raise err

proc sendHeaders*(
  strm: ClientStream,
  status: int,
  contentType = "",
  contentLen = -1
) {.async.} =
  template client: untyped = strm.client
  var headers = new(seq[byte])
  headers[] = newSeq[byte]()
  client.hpackEncode(headers[], ":status", $status)
  if contentType.len > 0:
    client.hpackEncode(headers[], "content-type", contentType)
  if contentLen > -1:
    client.hpackEncode(headers[], "content-length", $contentLen)
  let finish = contentLen <= 0
  await strm.sendHeaders(headers, finish)
