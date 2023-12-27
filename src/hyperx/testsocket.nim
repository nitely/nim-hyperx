import std/asyncdispatch
import ./queue

type
  TestSocket* = ref object
    data*: QueueAsync[string]
    isConnected*: bool
    hostname*: string
    port*: Port

proc newMySocket*(): TestSocket =
  TestSocket(
    data: newQueue[string](10),
    isConnected: false,
    hostname: "",
    port: Port 0
  )

proc recv*(s: TestSocket, i: int): Future[string] {.async.} =
  result = await s.data.pop()

proc send*(s: TestSocket, data: ptr byte, ln: int) {.async.} =
  discard

proc send*(s: TestSocket, data: string) {.async.} =
  discard

proc connect*(s: TestSocket, hostname: string, port: Port) {.async.} =
  s.isConnected = true
  s.hostname = hostname
  s.port = port

proc close*(s: TestSocket) =
  s.isConnected = false
  proc callback() =
    waitFor s.data.put("")
  callSoon callback
  
