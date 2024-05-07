#[

=====================================================
Nim -- a Compiler for Nim. https://nim-lang.org/

Copyright (C) 2006-2024 Andreas Rumpf. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

[ MIT license: http://www.opensource.org/licenses/mit-license.php ]

]#

# Some of this is from Nim's std lib

include std/asyncnet

const BufferSize2 = 128 * 1024

type
  AsyncSock* = ref object
    fd: SocketHandle
    closed: bool
    isBuffered: bool
    buffer: array[BufferSize2, char]
    bufferAuxRecv: string
    bufferAuxSend: string
    currPos: int
    bufLen: int
    isSsl: bool
    sslHandle: SslPtr
    sslContext: SslContext
    bioIn: BIO
    bioOut: BIO
    sslNoShutdown: bool
    domain: Domain
    sockType: SockType
    protocol: Protocol

proc newAsyncSock(
  fd: AsyncFD,
  domain: Domain = AF_INET,
  sockType: SockType = SOCK_STREAM,
  protocol: Protocol = IPPROTO_TCP,
  buffered = true,
  inheritable = defined(nimInheritHandles)
): AsyncSock =
  assert fd != osInvalidSocket.AsyncFD
  new(result)
  result.fd = fd.SocketHandle
  fd.SocketHandle.setBlocking(false)
  if not fd.SocketHandle.setInheritable(inheritable):
    raiseOSError(osLastError())
  result.isBuffered = buffered
  result.domain = domain
  result.sockType = sockType
  result.protocol = protocol
  if buffered:
    result.currPos = 0

proc newAsyncSock*(
  domain: Domain = AF_INET,
  sockType: SockType = SOCK_STREAM,
  protocol: Protocol = IPPROTO_TCP,
  buffered = true,
  inheritable = defined(nimInheritHandles)
): AsyncSock =
  let fd = createAsyncNativeSocket(domain, sockType, protocol, inheritable)
  if fd.SocketHandle == osInvalidSocket:
    raiseOSError(osLastError())
  result = newAsyncSock(fd, domain, sockType, protocol, buffered, inheritable)

proc setSockOpt*(socket: AsyncSock, opt: SOBool, value: bool,
    level = SOL_SOCKET) {.tags: [WriteIOEffect].} =
  ## Sets option `opt` to a boolean value specified by `value`.
  var valuei = cint(if value: 1 else: 0)
  setSockOptInt(socket.fd, cint(level), toCInt(opt), valuei)

proc bindAddr*(socket: AsyncSock, port = Port(0), address = "") {.
  tags: [ReadIOEffect].} =
  var realaddr = address
  if realaddr == "":
    case socket.domain
    of AF_INET6: realaddr = "::"
    of AF_INET: realaddr = "0.0.0.0"
    else:
      raise newException(ValueError,
        "Unknown socket address family and no address specified to bindAddr")

  var aiList = getAddrInfo(realaddr, port, socket.domain)
  if bindAddr(socket.fd, aiList.ai_addr, aiList.ai_addrlen.SockLen) < 0'i32:
    freeAddrInfo(aiList)
    raiseOSError(osLastError())
  freeAddrInfo(aiList)

proc listen*(socket: AsyncSock, backlog = SOMAXCONN) {.tags: [
    ReadIOEffect].} =
  if listen(socket.fd, backlog) < 0'i32: raiseOSError(osLastError())

proc acceptAddr*(socket: AsyncSock, flags = {SocketFlag.SafeDisconn},
                 inheritable = defined(nimInheritHandles)):
      owned(Future[tuple[address: string, client: AsyncSock]]) =
  var retFuture = newFuture[tuple[address: string, client: AsyncSock]]("asyncnet.acceptAddr")
  var fut = acceptAddr(socket.fd.AsyncFD, flags, inheritable)
  fut.callback =
    proc (future: Future[tuple[address: string, client: AsyncFD]]) =
      assert future.finished
      if future.failed:
        retFuture.fail(future.readError)
      else:
        let resultTup = (future.read.address,
                         newAsyncSock(future.read.client, socket.domain,
                         socket.sockType, socket.protocol, socket.isBuffered, inheritable))
        retFuture.complete(resultTup)
  return retFuture

proc accept*(
  socket: AsyncSock,
  flags = {SocketFlag.SafeDisconn}
): owned(Future[AsyncSock]) =
  var retFut = newFuture[AsyncSock]("asyncnet.accept")
  var fut = acceptAddr(socket, flags)
  fut.callback =
    proc (future: Future[tuple[address: string, client: AsyncSock]]) =
      assert future.finished
      if future.failed:
        retFut.fail(future.readError)
      else:
        retFut.complete(future.read.client)
  return retFut

proc wrapSocket*(ctx: SslContext, socket: AsyncSock) =
  socket.isSsl = true
  socket.sslContext = ctx
  socket.sslHandle = SSL_new(socket.sslContext.context)
  if socket.sslHandle == nil:
    raiseSSLError()
  socket.bioIn = bioNew(bioSMem())
  socket.bioOut = bioNew(bioSMem())
  sslSetBio(socket.sslHandle, socket.bioIn, socket.bioOut)
  socket.sslNoShutdown = true

proc wrapConnectedSocket*(
  ctx: SslContext,
  socket: AsyncSock,
  handshake: SslHandshakeType,
  hostname: string = ""
) =
  wrapSocket(ctx, socket)
  case handshake
  of handshakeAsClient:
    if hostname.len > 0 and not isIpAddress(hostname):
      discard SSL_set_tlsext_host_name(socket.sslHandle, hostname)
    sslSetConnectState(socket.sslHandle)
  of handshakeAsServer:
    sslSetAcceptState(socket.sslHandle)

proc sendPendingSslData2(
  socket: AsyncSock,
  flags: set[SocketFlag]
) {.async.} =
  let len = bioCtrlPending(socket.bioOut)
  if len > 0:
    if len > socket.bufferAuxRecv.len:
      socket.bufferAuxRecv.setLen len
    let read = bioRead(socket.bioOut, cast[cstring](addr socket.bufferAuxRecv[0]), len)
    assert read != 0
    if read < 0:
      raiseSSLError()
    await send(socket.fd.AsyncFD, addr socket.bufferAuxRecv[0], read, flags)

proc sendPendingSslData22(
  socket: AsyncSock,
  flags: set[SocketFlag]
) {.async.} =
  let len = bioCtrlPending(socket.bioOut)
  if len > 0:
    if len > socket.bufferAuxSend.len:
      socket.bufferAuxSend.setLen len
    let read = bioRead(socket.bioOut, cast[cstring](addr socket.bufferAuxSend[0]), len)
    assert read != 0
    if read < 0:
      raiseSSLError()
    await send(socket.fd.AsyncFD, addr socket.bufferAuxSend[0], read, flags)

proc getSslError(socket: AsyncSock, err: cint): cint =
  assert socket.isSsl
  assert err < 0
  var ret = SSL_get_error(socket.sslHandle, err.cint)
  case ret
  of SSL_ERROR_ZERO_RETURN:
    raiseSSLError("TLS/SSL connection failed to initiate, socket closed prematurely.")
  of SSL_ERROR_WANT_CONNECT, SSL_ERROR_WANT_ACCEPT:
    return ret
  of SSL_ERROR_WANT_WRITE, SSL_ERROR_WANT_READ:
    return ret
  of SSL_ERROR_WANT_X509_LOOKUP:
    raiseSSLError("Function for x509 lookup has been called.")
  of SSL_ERROR_SYSCALL, SSL_ERROR_SSL:
    socket.sslNoShutdown = true
    raiseSSLError()
  else: raiseSSLError("Unknown Error")

proc appeaseSsl2(
  socket: AsyncSock,
  flags: set[SocketFlag],
  sslError: cint
): Future[bool] {.async.} =
  ## Returns `true` if `socket` is still connected, otherwise `false`.
  result = true
  case sslError
  of SSL_ERROR_WANT_WRITE:
    await sendPendingSslData2(socket, flags)
  of SSL_ERROR_WANT_READ:
    if BufferSize2 > socket.bufferAuxRecv.len:
      socket.bufferAuxRecv.setLen BufferSize2
    let length = await recvInto(
      socket.fd.AsyncFD, addr socket.bufferAuxRecv[0], BufferSize2, flags
    )
    if length > 0:
      let ret = bioWrite(socket.bioIn, cast[cstring](addr socket.bufferAuxRecv[0]), length.cint)
      if ret < 0:
        raiseSSLError()
    elif length == 0:
      # connection not properly closed by remote side or connection dropped
      SSL_set_shutdown(socket.sslHandle, SSL_RECEIVED_SHUTDOWN)
      result = false
  else:
    raiseSSLError("Cannot appease SSL.")

proc appeaseSsl22(
  socket: AsyncSock,
  flags: set[SocketFlag],
  sslError: cint
): Future[bool] {.async.} =
  ## Returns `true` if `socket` is still connected, otherwise `false`.
  result = true
  case sslError
  of SSL_ERROR_WANT_WRITE:
    await sendPendingSslData22(socket, flags)
  of SSL_ERROR_WANT_READ:
    if BufferSize2 > socket.bufferAuxSend.len:
      socket.bufferAuxSend.setLen BufferSize2
    let length = await recvInto(
      socket.fd.AsyncFD, addr socket.bufferAuxSend[0], BufferSize2, flags
    )
    if length > 0:
      let ret = bioWrite(socket.bioIn, cast[cstring](addr socket.bufferAuxSend[0]), length.cint)
      if ret < 0:
        raiseSSLError()
    elif length == 0:
      # connection not properly closed by remote side or connection dropped
      SSL_set_shutdown(socket.sslHandle, SSL_RECEIVED_SHUTDOWN)
      result = false
  else:
    raiseSSLError("Cannot appease SSL.")

template sslLoop2(
  socket: AsyncSock,
  flags: set[SocketFlag],
  op: untyped
) =
  var opResult {.inject.} = -1.cint
  while opResult < 0:
    ErrClearError()
    opResult = op
    let err =
      if opResult < 0:
        getSslError(socket, opResult.cint)
      else:
        SSL_ERROR_NONE
    await sendPendingSslData2(socket, flags)
    if opResult < 0:
      let fut = appeaseSsl2(socket, flags, err.cint)
      yield fut
      if not fut.read():
        if SocketFlag.SafeDisconn in flags:
          opResult = 0.cint
          break
        else:
          raiseSSLError("Socket has been disconnected")

template sslLoop22(
  socket: AsyncSock,
  flags: set[SocketFlag],
  op: untyped
) =
  var opResult {.inject.} = -1.cint
  while opResult < 0:
    ErrClearError()
    opResult = op
    let err =
      if opResult < 0:
        getSslError(socket, opResult.cint)
      else:
        SSL_ERROR_NONE
    await sendPendingSslData22(socket, flags)
    if opResult < 0:
      let fut = appeaseSsl22(socket, flags, err.cint)
      yield fut
      if not fut.read():
        if SocketFlag.SafeDisconn in flags:
          opResult = 0.cint
          break
        else:
          raiseSSLError("Socket has been disconnected")

template readInto2(
  buf: pointer,
  size: int, 
  socket: AsyncSock,
  flags: set[SocketFlag]
): int =
  doAssert not socket.closed
  doAssert socket.isSsl
  var res = 0
  sslLoop2(
    socket, flags, sslRead(socket.sslHandle, cast[cstring](buf), size.cint)
  )
  res = opResult
  res

template readIntoBuf2(
  socket: AsyncSock,
  flags: set[SocketFlag]
): int =
  var size = readInto2(addr socket.buffer[0], BufferSize2, socket, flags)
  socket.currPos = 0
  socket.bufLen = size
  size

proc recvInto*(
  socket: AsyncSock,
  buf: pointer,
  size: int,
  flags = {SocketFlag.SafeDisconn}
): Future[int] {.async.} =
  doAssert socket.isBuffered
  let originalBufPos = socket.currPos
  if socket.bufLen == 0:
    let res = socket.readIntoBuf2(flags - {SocketFlag.Peek})
    if res == 0:
      return 0
  var read = 0
  var cbuf = cast[cstring](buf)
  while read < size:
    if socket.currPos >= socket.bufLen:
      let res = socket.readIntoBuf2(flags - {SocketFlag.Peek})
      if res == 0:
        break
    let chunk = min(socket.bufLen-socket.currPos, size-read)
    copyMem(addr(cbuf[read]), addr(socket.buffer[socket.currPos]), chunk)
    read += chunk
    socket.currPos += chunk
  result = read

proc send*(
  socket: AsyncSock,
  buf: pointer,
  size: int,
  flags = {SocketFlag.SafeDisconn}
) {.async.} =
  assert socket != nil
  assert(not socket.closed, "Cannot `send` on a closed socket")
  doAssert socket.isSsl
  sslLoop22(
    socket, flags, sslWrite(socket.sslHandle, cast[cstring](buf), size.cint)
  )
  await sendPendingSslData22(socket, flags)

proc send*(
  socket: AsyncSock,
  data: string,
  flags = {SocketFlag.SafeDisconn}) {.async.} =
  assert socket != nil
  doAssert socket.isSsl
  var copy = data
  sslLoop22(socket, flags,
    sslWrite(socket.sslHandle, cast[cstring](addr copy[0]), copy.len.cint))
  await sendPendingSslData22(socket, flags)

proc close*(socket: AsyncSock) =
  if socket.closed: return
  defer:
    socket.fd.AsyncFD.closeSocket()
    socket.closed = true
  doAssert socket.isSsl
  let res =
    if not socket.sslNoShutdown and SSL_in_init(socket.sslHandle) == 0:
      ErrClearError()
      SSL_shutdown(socket.sslHandle)
    else:
      0
  SSL_free(socket.sslHandle)
  if res == 0:
    discard
  elif res != 1:
    raiseSSLError()

proc isClosed*(socket: AsyncSock): bool =
  return socket.closed

proc connect*(socket: AsyncSock, address: string, port: Port) {.async.} =
  await connect(socket.fd.AsyncFD, address, port, socket.domain)
  doAssert socket.isSsl
  if not isIpAddress(address):
    # Set the SNI address for this connection. This call can fail if
    # we're not using TLSv1+.
    discard SSL_set_tlsext_host_name(socket.sslHandle, address)
  let flags = {SocketFlag.SafeDisconn}
  sslSetConnectState(socket.sslHandle)
  sslLoop2(socket, flags, sslDoHandshake(socket.sslHandle))
