{.define: ssl.}
{.define: hyperxSanityCheck.}

import std/asyncdispatch
import ../../src/hyperx/client
import ../../src/hyperx/limiter
import ../../src/hyperx/errors
import ./tutils.nim
from ../../src/hyperx/clientserver import stgWindowSize

const strmsPerClient = 1123
const clientsCount = 13
const strmsInFlight = 100
const dataFrameLen = 1
#const dataFrameLen = stgWindowSize.int * 2 + 123

proc send(strm: ClientStream) {.async.} =
  await strm.sendHeaders(
    @[
      (":method", "POST"),
      (":scheme", "https"),
      (":path", "/file/"),
      (":authority", "foo.bar"),
      ("user-agent", "HyperX/0.1"),
      ("content-type", "text/plain")
    ],
    finish = false
  )
  let data = newStringRef newString(dataFrameLen)
  while true:
    await strm.sendBody(data, finish = false)

proc recv(strm: ClientStream) {.async.} =
  var data = newStringref()
  await strm.recvHeaders(data)
  doAssert data[] == ":status: 200\r\n"
  data[].setLen 0
  while not strm.recvEnded:
    await strm.recvBody(data)
    await strm.cancel(errCancel)  # CANCEL

proc spawnStream(
  client: ClientContext,
  checked: ref int
) {.async.} =
  let strm = client.newClientStream()
  with strm:
    let sendFut = strm.send()
    let recvFut = strm.recv()
    try:
      await recvFut
    except StrmError as err:
      doAssert err.typ == hxLocalErr
      doAssert err.code == errStreamClosed
    try:
      await sendFut
    except StrmError as err:
      doAssert err.typ == hxLocalErr
      doAssert err.code == errStreamClosed
    inc checked[]
    return

proc spawnClient(
  checked: ref int
) {.async.} =
  var client = newClient(localHost, localPort)
  with client:
    var stmsCount = 0
    let lt = newLimiter(strmsInFlight)
    while stmsCount < strmsPerClient:
      if not client.isConnected:
        return
      await lt.spawn spawnStream(client, checked)
      inc stmsCount
      if stmsCount >= strmsPerClient:
        break
    while not lt.isEmpty:
      await lt.wait()

proc main() {.async.} =
  let checked = new(int)
  checked[] = 0
  var clients = newSeq[Future[void]]()
  for _ in 0 .. clientsCount-1:
    clients.add spawnClient(checked)
  for clientFut in clients:
    await clientFut
  doAssert checked[] == clientsCount * strmsPerClient
  echo "checked ", $checked[]

(proc =
  waitFor main()
  doAssert not hasPendingOperations()
  echo "ok"
)()
