import std/asyncdispatch
import ./queue

type
  TestSocket* = ref object
    recvData, sentData: QueueAsync[seq[byte]]
    # need buff because recvData item can exceed recvInto size
    recvBuff, sentBuff: seq[byte]
    recvIdx, sentIdx: int
    isConnected*: bool
    hostname*: string
    port*: Port

proc newMySocket*(): TestSocket =
  TestSocket(
    recvData: newQueue[seq[byte]](1000),
    sentData: newQueue[seq[byte]](1000),
    recvBuff: newSeq[byte](),
    recvIdx: 0,
    sentBuff: newSeq[byte](),
    sentIdx: 0,
    isConnected: false,
    hostname: "",
    port: Port 0
  )

proc putRecvData*(s: TestSocket, data: seq[byte]) {.async.} =
  await s.recvData.put data

proc sentInto*(s: TestSocket, buff: pointer, size: int): Future[int] {.async.} =
  if not s.isConnected:
    return 0
  while s.sentIdx+size > s.sentBuff.len:
    let L = s.sentBuff.len
    s.sentBuff.add await s.sentData.pop()
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
    s.recvBuff.add await s.recvData.pop()
    if s.recvBuff.len == L:
      s.isConnected = false
      return 0
  copyMem(buff, addr s.recvBuff[s.recvIdx], size)
  s.recvIdx += size
  return size

proc send*(s: TestSocket, data: ptr byte, ln: int) {.async.} =
  doAssert ln > 0
  var dataCopy = newSeq[byte](ln)
  copyMem(addr dataCopy[0], data, ln)
  await s.sentData.put dataCopy

proc send*(s: TestSocket, data: seq[byte]) {.async.} =
  await s.sentData.put data

proc connect*(s: TestSocket, hostname: string, port: Port) {.async.} =
  doAssert not s.isConnected
  s.isConnected = true
  s.hostname = hostname
  s.port = port

proc close*(s: TestSocket) =
  s.isConnected = false
  #XXX SIGSEGV in orc
  #s.recvData.close()
  proc terminate() =
    asyncCheck s.recvData.put newSeq[byte]()
    s.sentData.close()
  callSoon terminate
