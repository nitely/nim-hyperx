import std/asyncdispatch
import ./queue

type
  TestSocket* = ref object
    data*: QueueAsync[string]
    buff: string
    i: int
    sent*: seq[byte]
    isConnected*: bool
    hostname*: string
    port*: Port

proc newMySocket*(): TestSocket =
  TestSocket(
    data: newQueue[string](100),
    buff: "",
    i: 0,
    isConnected: false,
    hostname: "",
    port: Port 0
  )

func isClosed*(s: TestSocket): bool =
  false

proc recvInto*(s: TestSocket, buff: pointer, size: int): Future[int] {.async.} =
  ## Simulates socket recv
  if not s.isConnected:
    return 0
  while s.i+size > s.buff.len:
    let L = s.buff.len
    s.buff.add await s.data.pop()
    if s.buff.len == L:
      s.isConnected = false
      return 0
  copyMem(buff, addr s.buff[s.i], size)
  s.i += size
  return size

proc send*(s: TestSocket, data: ptr byte, ln: int) {.async.} =
  if ln > 0:
    var bytes = newSeq[byte](ln)
    copyMem(addr bytes[0], data, ln)
    s.sent.add bytes

proc send*(s: TestSocket, data: string) {.async.} =
  for c in data:
    s.sent.add c.byte

proc connect*(s: TestSocket, hostname: string, port: Port) {.async.} =
  doAssert not s.isConnected
  s.isConnected = true
  s.hostname = hostname
  s.port = port

proc close*(s: TestSocket) =
  s.isConnected = false
  #XXX SIGSEGV in orc
  #s.data.close()
  proc terminateRecv() =
    asyncCheck s.data.put("")
  callSoon terminateRecv
