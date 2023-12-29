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

proc recv*(s: TestSocket, i: int): Future[string] {.async.} =
  ## Simulates socket recv
  if not s.isConnected:
    return ""
  while s.i+i > s.buff.len:
    let L = s.buff.len
    s.buff.add await s.data.pop()
    if s.buff.len == L:
      s.isConnected = false
      return ""
  result = s.buff[s.i .. s.i+i-1]
  s.i += i

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
  proc terminateRecv() =
    asyncCheck s.data.put("")
  callSoon terminateRecv
  
