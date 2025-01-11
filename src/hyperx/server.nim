## HTTP/2 server

import std/asyncdispatch
import std/asyncnet
import std/net
when defined(ssl):
  import std/exitprocs

import ./clientserver
import ./stream
import ./queue
import ./limiter
import ./errors
import ./utils

when defined(hyperxTest):
  import ./testsocket
when defined(hyperxStats):
  export echoStats

export
  with,
  recvHeaders,
  recvBody,
  recvTrailers,
  recvEnded,
  sendHeaders,
  sendBody,
  sendEnded,
  cancel,
  ClientStream,
  newClientStream,
  ClientContext,
  HyperxConnError,
  HyperxStrmError,
  HyperxError,
  gracefulClose,
  isGracefulClose,
  trace

var sslContext {.threadvar, definedSsl.}: SslContext

proc destroySslContext() {.noconv, definedSsl.} =
  sslContext.destroyContext()

proc defaultSslContext(
  certFile, keyFile: string
): SslContext {.raises: [HyperxConnError], definedSsl.} =
  if not sslContext.isNil:
    return sslContext
  sslContext = defaultSslContext(ctServer, certFile, keyFile)
  addExitProc(destroySslContext)
  return sslContext

when not defined(hyperxTest):
  proc newMySocketSsl(
    certFile = "",
    keyFile = ""
  ): MyAsyncSocket {.raises: [HyperxConnError], definedSsl.} =
    result = newMySocket()
    tryCatch wrapSocket(defaultSslContext(certFile, keyFile), result)

type
  ServerContext* = ref object
    sock: MyAsyncSocket
    hostname: string
    port: Port
    isConnected: bool

const defSsl = defined(ssl)

proc newServer*(
  hostname: string,
  port: Port,
  sslCertFile = "",
  sslKeyFile = "",
  ssl: static[bool] = true
): ServerContext {.raises: [HyperxConnError].} =
  when ssl and not defSsl:
    {.error: "this lib needs -d:ssl".}
  template sock: untyped =
    when ssl:
      newMySocketSsl(sslCertFile, sslKeyFile)
    else:
      newMySocket()
  ServerContext(
    sock: sock,
    hostname: hostname,
    port: port,
    isConnected: false
  )

proc close*(server: ServerContext) {.raises: [HyperxConnError].} =
  if not server.isConnected:
    return
  server.isConnected = false
  tryCatch server.sock.close()

proc listen(server: ServerContext) {.raises: [HyperxConnError].} =
  tryCatch:
    server.sock.setSockOpt(OptReuseAddr, true)
    server.sock.setSockOpt(OptReusePort, true)
    server.sock.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)
    server.sock.bindAddr server.port
    server.sock.listen()

# XXX dont allow receive push promise

# XXX limit number of active clients
proc recvClient*(server: ServerContext): Future[ClientContext] {.async.} =
  tryCatch:
    # note OptNoDelay is inherited from server.sock
    let sock = await server.sock.accept()
    when defined(ssl):
      if server.sock.isSsl:
        when not defined(hyperxTest):
          doAssert not sslContext.isNil
        wrapConnectedSocket(
          sslContext, sock, handshakeAsServer, server.hostname
        )
    return newClient(ctServer, sock, server.hostname)

template with*(server: ServerContext, body: untyped): untyped =
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
    debugErr2 err
    doAssert not client.isConnected
    if client.error != nil:
      raise newConnError(client.error.msg, err)
    raise err

proc sendHeaders*(
  strm: ClientStream,
  status: int,
  contentType = "",
  contentLen = -1
): Future[void] =
  template client: untyped = strm.client
  template stream: untyped = strm.stream
  check stream.state in strmStateHeaderSendAllowed,
    newErrorOrDefault(stream.error, newStrmError hyxStreamClosed)
  var headers = newSeq[byte]()
  client.hpackEncode(headers, ":status", $status)
  if contentType.len > 0:
    client.hpackEncode(headers, "content-type", contentType)
  if contentLen > -1:
    client.hpackEncode(headers, "content-length", $contentLen)
  let finish = contentLen <= 0
  result = strm.sendHeadersImpl(headers, finish)

type StreamCallback* =
  proc (stream: ClientStream): Future[void] {.closure, gcsafe.}

proc processStreamHandler(
  strm: ClientStream,
  callback: StreamCallback
) {.async.} =
  try:
    with strm:
      await callback(strm)
  except HyperxError:
    debugErr2 getCurrentException()
    debugErr getCurrentException()

proc processClientHandler(
  client: ClientContext,
  callback: StreamCallback
) {.async.} =
  try:
    with client:
      while client.isConnected:
        let strm = await client.recvStream()
        asyncCheck processStreamHandler(strm, callback)
  except HyperxError:
    debugErr2 getCurrentException()
    debugErr getCurrentException()
  when defined(hyperxStats):
    echoStats client

const defaultMaxConns = int.high

proc serve*(
  server: ServerContext,
  callback: StreamCallback,
  maxConnections = defaultMaxConns
) {.async.} =
  let lt = newLimiter maxConnections
  try:
    with server:
      while server.isConnected:
        let client = await server.recvClient()
        await lt.spawn processClientHandler(client, callback)
  finally:
    await lt.join()
