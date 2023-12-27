import std/asyncdispatch
import ./queue

type
  TestSocket* = ref object
    data*: QueueAsync[string]
    buff: string
    i: int
    isConnected*: bool
    hostname*: string
    port*: Port

proc newMySocket*(): TestSocket =
  TestSocket(
    data: newQueue[string](10),
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
  discard

proc send*(s: TestSocket, data: string) {.async.} =
  discard

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
  
