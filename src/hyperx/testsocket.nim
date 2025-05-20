
when not defined(ssl):
  {.error: "this lib needs -d:ssl".}

import std/asyncdispatch
import std/asyncnet
import std/net

import ./signal

type
  TestSocket* = ref object
    recvSig, sentSig: SignalAsync
    recvBuff, sentBuff: seq[byte]
    recvIdx, sentIdx: int
    isConnected*: bool
    hostname*: string
    port*: Port
    isSsl*: bool

proc newMySocket*: TestSocket =
  TestSocket(
    recvSig: newSignal(),
    sentSig: newSignal(),
    recvBuff: newSeq[byte](),
    recvIdx: 0,
    sentBuff: newSeq[byte](),
    sentIdx: 0,
    isConnected: false,
    hostname: "",
    port: Port 0,
    isSsl: false
  )

proc newMySocketSsl*(certFile = "", keyFile = ""): TestSocket =
  result = newMySocket()
  result.isSsl = true

proc putRecvData*(s: TestSocket, data: seq[byte]) {.async.} =
  s.recvBuff.add data
  s.recvSig.trigger()

proc sentInto*(s: TestSocket, buff: pointer, size: int): Future[int] {.async.} =
  if not s.isConnected:
    return 0
  while s.sentIdx+size > s.sentBuff.len:
    let L = s.sentBuff.len
    await s.sentSig.waitfor()
    if s.sentBuff.len == L:
      s.isConnected = false
      return 0
  copyMem(buff, addr s.sentBuff[s.sentIdx], size)
  s.sentIdx += size
  return size

func isClosed*(s: TestSocket): bool =
  false

proc recvInto*(s: TestSocket, buff: pointer, size: int): Future[int] {.async.} =
  ## Simulates socket recv
  if not s.isConnected:
    return 0
  while s.recvIdx+size > s.recvBuff.len:
    let L = s.recvBuff.len
    await s.recvSig.waitfor()
    if s.recvBuff.len == L:
      s.isConnected = false
      return 0
  copyMem(buff, addr s.recvBuff[s.recvIdx], size)
  s.recvIdx += size
  return size

proc send*(s: TestSocket, data: pointer, ln: int) {.async.} =
  doAssert ln > 0
  var dataCopy = newSeq[byte](ln)
  copyMem(addr dataCopy[0], data, ln)
  s.sentBuff.add dataCopy
  s.sentSig.trigger()

proc send*(s: TestSocket, data: seq[byte]) {.async.} =
  s.sentBuff.add data
  s.sentSig.trigger()

proc send*(s: TestSocket, data: string) {.async.} =
  doAssert data.len > 0
  var dataCopy = newSeq[byte](data.len)
  copyMem(addr dataCopy[0], unsafeAddr data[0], data.len)
  s.sentBuff.add dataCopy
  s.sentSig.trigger()

proc connect*(s: TestSocket, hostname: string, port: Port) {.async.} =
  doAssert not s.isConnected
  s.isConnected = true
  s.hostname = hostname
  s.port = port

proc close*(s: TestSocket) =
  s.isConnected = false
  s.recvSig.trigger()
  s.recvSig.close()
  s.sentSig.close()

# XXX untested server funcs

proc setSockOpt*(s: TestSocket, opt = OptReuseAddr, x = true, level = 0) =
  discard

proc bindAddr*(s: TestSocket, port = Port(0)) =
  doAssert not s.isConnected
  s.port = port

proc listen*(s: TestSocket) =
  doAssert not s.isConnected
  s.isConnected = true

proc accept*(s: TestSocket): Future[TestSocket] {.async.} =
  result = if s.isSsl:
    newMySocketSsl()
  else:
    newMySocket()
  result.isConnected = true

proc wrapConnectedSocket*(
  ctx: SslContext;
  socket: TestSocket;
  handshake: SslHandshakeType;
  hostname = ""
) =
  doAssert handshake == handshakeAsServer
  socket.hostname = hostname
