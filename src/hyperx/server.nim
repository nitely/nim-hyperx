## HTTP/2 server

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
  isGracefulClose

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
    ssl: bool,
    certFile = "",
    keyFile = ""
  ): MyAsyncSocket {.raises: [HyperxConnError].} =
    result = nil
    try:
      result = newAsyncSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, buffered = true)
      doAssert result != nil
      if ssl:
        wrapSocket(defaultSslContext(certFile, keyFile), result)
    except CatchableError as err:
      debugInfo err.getStackTrace()
      debugInfo err.msg
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
  sslKeyFile = "",
  ssl = true
): ServerContext {.raises: [HyperxConnError].} =
  ServerContext(
    sock: newMySocket(
      ssl,
      certFile = sslCertFile,
      keyFile = sslKeyFile
    ),
    hostname: hostname,
    port: port,
    isConnected: false
  )

proc close*(server: ServerContext) {.raises: [HyperxConnError].} =
  if not server.isConnected:
    return
  server.isConnected = false
  try:
    server.sock.close()
  except CatchableError as err:
    debugInfo err.getStackTrace()
    debugInfo err.msg
    raise newHyperxConnError(err.msg)
  except Defect as err:
    raise err
  except Exception as err:
    debugInfo err.getStackTrace()
    debugInfo err.msg
    raise newException(Defect, err.msg)

proc listen(server: ServerContext) {.raises: [HyperxConnError].} =
  try:
    server.sock.setSockOpt(OptReuseAddr, true)
    server.sock.setSockOpt(OptReusePort, true)
    server.sock.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)
    server.sock.bindAddr server.port
    server.sock.listen()
  except OSError, ValueError:
    let err = getCurrentException()
    debugInfo err.getStackTrace()
    debugInfo err.msg
    raise newHyperxConnError(err.msg)

# XXX dont allow receive push promise

# XXX limit number of active clients
proc recvClient*(server: ServerContext): Future[ClientContext] {.async.} =
  try:
    # note OptNoDelay is inherited from server.sock
    let sock = await server.sock.accept()
    if server.sock.isSsl:
      when not defined(hyperxTest):
        doAssert not sslContext.isNil
      wrapConnectedSocket(
        sslContext, sock, handshakeAsServer, server.hostname
      )
    result = newClient(ctServer, sock, server.hostname)
  except CatchableError as err:
    debugInfo err.getStackTrace()
    debugInfo err.msg
    raise newHyperxConnError(err.msg)

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
    doAssert not client.isConnected
    if client.error != nil:
      # https://github.com/nim-lang/Nim/issues/15182
      debugInfo client.error.getStackTrace()
      debugInfo client.error.msg
      raise newHyperxConnError(client.error.msg)
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
    newErrorOrDefault(stream.error, newStrmError errStreamClosed)
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
    debugInfo getCurrentException().getStackTrace()
    debugInfo getCurrentException().msg

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
    debugInfo getCurrentException().getStackTrace()
    debugInfo getCurrentException().msg
  when defined(hyperxStats):
    echoStats client

proc serve*(
  server: ServerContext,
  callback: StreamCallback
) {.async.} =
  with server:
    while server.isConnected:
      let client = await server.recvClient()
      asyncCheck processClientHandler(client, callback)
