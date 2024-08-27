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
  #HyperxErrTyp,
  HyperxSockDomain

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
    domain: Domain,
    protocol: Protocol,
    ssl: bool,
    certFile = "",
    keyFile = ""
  ): MyAsyncSocket {.raises: [HyperxConnError].} =
    doAssert domain in {AF_UNIX, AF_INET, AF_INET6}
    doAssert protocol in {IPPROTO_IP, IPPROTO_TCP}
    try:
      result = newAsyncSocket(domain, SOCK_STREAM, protocol, buffered = true)
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
    domain: HyperxSockDomain
    isConnected: bool

proc newServer*(
  hostname: string,
  port: Port,
  sslCertFile = "",
  sslKeyFile = "",
  ssl = true,
  domain = hyxInet
): ServerContext =
  ServerContext(
    sock: newMySocket(
      domain.addrFamily(),
      domain.ipProto(),
      ssl,
      certFile = sslCertFile,
      keyFile = sslKeyFile
    ),
    hostname: hostname,
    port: port,
    domain: domain,
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
    case server.domain
    of hyxInet, hyxInet6:
      server.sock.setSockOpt(OptReuseAddr, true)
      server.sock.setSockOpt(OptReusePort, true)
      server.sock.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)
      server.sock.bindAddr server.port
    of hyxUnix:
      # XXX tryRemoveFile to avoid OSError
      server.sock.bindUnix server.hostname
    server.sock.listen()
  except OSError, ValueError:
    let err = getCurrentException()
    debugInfo err.getStackTrace()
    debugInfo err.msg
    # XXX probably not a conn error
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
    result = newClient(
      ctServer, sock, server.hostname, server.port, server.domain
    )
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
  var headers = new(seq[byte])
  headers[] = newSeq[byte]()
  client.hpackEncode(headers[], ":status", $status)
  if contentType.len > 0:
    client.hpackEncode(headers[], "content-type", contentType)
  if contentLen > -1:
    client.hpackEncode(headers[], "content-length", $contentLen)
  let finish = contentLen <= 0
  result = strm.sendHeadersImpl(headers, finish)
