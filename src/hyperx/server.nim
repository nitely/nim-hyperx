## HTTP/2 server

import std/asyncdispatch
import std/asyncnet
import std/net
import std/nativesockets
when defined(ssl):
  import ./atexit

import ./clientserver
import ./stream
import ./signal
import ./limiter
import ./errors
import ./utils
import ./pipes

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
  trace,
  onClose

var sslContext {.threadvar, definedSsl.}: SslContext

proc destroySslContext() {.noconv, definedSsl.} =
  if not sslContext.isNil:
    sslContext.destroyContext()

proc destroyServerSslContext* =
  definedSsl:
    destroySslContext()

proc defaultSslContext(
  certFile, keyFile: string
): SslContext {.raises: [HyperxConnError], definedSsl.} =
  if not sslContext.isNil:
    return sslContext
  sslContext = defaultSslContext(ctServer, certFile, keyFile)
  atExitCall(destroySslContext)
  return sslContext

when not defined(hyperxTest):
  proc newMySocketSsl(
    certFile = "",
    keyFile = ""
  ): MyAsyncSocket {.raises: [HyperxConnError], definedSsl.} =
    result = newMySocket()
    catch wrapSocket(defaultSslContext(certFile, keyFile), result)

type
  ServerContext* = ref object
    sock: MyAsyncSocket
    hostname: string
    port: Port
    isConnected: bool

const isSslDefined = defined(ssl)

proc newServer*(
  hostname: string,
  port: Port,
  sslCertFile = "",
  sslKeyFile = "",
  ssl: static[bool] = true
): ServerContext {.raises: [HyperxConnError].} =
  when ssl and not isSslDefined:
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
  catch server.sock.close()

proc listen(server: ServerContext) {.raises: [HyperxConnError].} =
  catch:
    server.sock.setSockOpt(OptReuseAddr, true)
    server.sock.setSockOpt(OptReusePort, true)
    server.sock.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)
    server.sock.bindAddr server.port
    server.sock.listen()

proc recvClient*(server: ServerContext): Future[ClientContext] {.async.} =
  catch:
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
  discard getGlobalDispatcher()  # setup event loop
  try:
    server.isConnected = true
    server.listen()
    block:
      body
  finally:
    server.close()

# XXX remove
proc recvStream*(client: ClientContext): Future[ClientStream] {.async.} =
  try:
    while client.streamsRecv.len == 0:
      await client.streamsRecvSig.waitFor()
    let strm = client.streamsRecv.pop()
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
type SafeStreamCallback* =
  proc (stream: ClientStream): Future[void] {.nimcall, gcsafe.}
type ClientCallback* =
  proc (client: ClientContext): StreamCallback {.closure, gcsafe.}
type ServerCallback* =
  proc (server: ServerContext): ClientCallback {.closure, gcsafe.}

proc streamHandler(
  strm: ClientStream,
  callback: StreamCallback
) {.async.} =
  try:
    with strm:
      await callback(strm)
  except HyperxError:
    debugErr2 getCurrentException()
    debugErr getCurrentException()
  except CatchableError:
    debugErr2 getCurrentException()
    debugErr getCurrentException()
    when defined(hyperxLetItCrash):
      raise getCurrentException()

proc processStreams(
  client: ClientContext,
  callback: StreamCallback
) {.async.} =
  let lt = newLimiter int.high
  try:
    while client.isConnected:
      while client.streamsRecv.len == 0:
        await client.streamsRecvSig.waitFor()
      for strm in client.streamsRecv:
        lt.spawnCheck streamHandler(
          newClientStream(client, strm), callback
        )
      client.streamsRecv.setLen 0
      check lt.error == nil, lt.error
  finally:
    client.close()
    await lt.join()

proc clientHandler(
  client: ClientContext,
  callback: StreamCallback
) {.async.} =
  try:
    with client:
      await processStreams(client, callback)
  except QueueClosedError:
    debugErr2 getCurrentException()
    doAssert not client.isConnected
  except HyperxError:
    debugErr2 getCurrentException()
    debugErr getCurrentException()
  except CatchableError:
    debugErr2 getCurrentException()
    debugErr getCurrentException()
    when defined(hyperxLetItCrash):
      raise getCurrentException()
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
        await lt.spawn clientHandler(client, callback)
        check lt.error == nil, lt.error
  finally:
    # XXX close all clients somehow
    await lt.join()

proc serve*(
  server: ServerContext,
  serverCallback: ServerCallback,
  maxConnections = defaultMaxConns
) {.async.} =
  let lt = newLimiter maxConnections
  try:
    with server:
      let clientCallback = serverCallback server
      while server.isConnected:
        let client = await server.recvClient()
        await lt.spawn clientHandler(client, clientCallback(client))
        check lt.error == nil, lt.error
  finally:
    await lt.join()

type
  WorkerContext = object
    hostname: cstring
    port: Port
    callback: StreamCallback
    sslCertFile, sslKeyFile: cstring
    maxConnections: int

proc workerImpl(ctx: WorkerContext, ssl: static[bool] = true) =
  var server = newServer(
    $ctx.hostname, ctx.port, $ctx.sslCertFile, $ctx.sslKeyFile, ssl = ssl
  )
  try:
    waitFor server.serve(ctx.callback, ctx.maxConnections)
  finally:
    setGlobalDispatcher(nil)
    destroyServerSslContext()
    when defined(gcOrc):
      GC_runOrc()

proc workerSsl(ctx: ptr WorkerContext) {.thread, definedSsl.} =
  workerImpl(ctx[], ssl = true)

proc worker(ctx: ptr WorkerContext) {.thread.} =
  workerImpl(ctx[], ssl = false)

# XXX graceful shutdown
proc run*(
  hostname: string,
  port: Port,
  callback: SafeStreamCallback,
  sslCertFile = "",
  sslKeyFile = "",
  maxConnections = defaultMaxConns,
  threads = 1,
  ssl: static[bool] = true
) =
  when ssl and not isSslDefined:
    {.error: "this lib needs -d:ssl".}
  let ctx = WorkerContext(
    hostname: hostname,
    port: port,
    callback: callback,
    sslCertFile: sslCertFile,
    sslKeyFile: sslKeyFile,
    maxConnections: maxConnections
  )
  if threads == 1:
    workerImpl(ctx, ssl = ssl)
  else:
    var threads = newSeq[Thread[ptr WorkerContext]](threads)
    for i in 0 .. threads.len-1:
      when ssl:
        createThread(threads[i], workerSsl, addr ctx)
      else:
        createThread(threads[i], worker, addr ctx)
    for i in 0 .. threads.len-1:
      joinThread(threads[i])

type
  WorkerContext2 = object
    hostname: cstring
    callback: SafeStreamCallback
    chan: ptr Channel[AsyncFD]
    pipeR: PipeFd

proc clientWorker(ctx: ptr WorkerContext2) {.async.} =
  while true:
    var data = 0'u8
    let read = await ctx.pipeR.readInto(addr data, sizeof(data))
    doAssert read == 1
    let sock = ctx.chan[].recv()
    if sock != osInvalidSocket.AsyncFD:
      register(sock)
      let asock = newAsyncSocket(sock, AF_INET, SOCK_STREAM, IPPROTO_TCP, buffered = true)
      doAssert asock != nil
      let client = newClient(ctServer, asock, $ctx.hostname)
      asyncCheck clientHandler(client, ctx.callback)
    else:
      break

proc worker(ctx: ptr WorkerContext2) {.thread.} =
  discard getGlobalDispatcher()
  register(ctx.pipeR.AsyncFD)
  try:
    waitFor clientWorker(ctx)
  finally:
    unregister(ctx.pipeR.AsyncFD)

proc run2*(
  hostname: string,
  port: Port,
  callback: SafeStreamCallback,
  threads = 1
) =
  let socket = newSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
  socket.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)
  socket.bindAddr port
  socket.listen()
  let (pipeR, pipeW) = createPipe()
  var chan: Channel[AsyncFD]
  chan.open()
  var ctx = WorkerContext2(
    hostname: hostname,
    callback: callback,
    chan: addr chan,
    pipeR: pipeR
  )
  var threads = newSeq[Thread[ptr WorkerContext2]](threads)
  for i in 0 ..< threads.len:
    createThread(threads[i], worker, addr ctx)
  var client: Socket
  var data = 1'u8
  try:
    while true:
      socket.accept(client)
      chan.send client.getFd().AsyncFD
      pipeW.write(addr data, sizeof(data))
  finally:
    for _ in 0 ..< threads.len:
      chan.send osInvalidSocket.AsyncFD
      pipeW.write(addr data, sizeof(data))
    for i in 0 ..< threads.len:
      joinThread(threads[i])
    pipeR.close()
    socket.close()
  doAssert ctx.callback != nil  # keep alive
