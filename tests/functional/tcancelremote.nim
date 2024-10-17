{.define: ssl.}
{.define: hyperxSanityCheck.}

import std/asyncdispatch
import ../../src/hyperx/client
import ../../src/hyperx/signal
import ../../src/hyperx/errors
import ./tutils.nim
from ../../src/hyperx/clientserver import stgWindowSize

const strmsPerClient = 1123
const clientsCount = 13
const strmsInFlight = 100
#const dataFrameLen = 1
const dataFrameLen = stgWindowSize.int * 2 + 123

proc send(strm: ClientStream) {.async.} =
  await strm.sendHeaders(
    @[
      (":method", "POST"),
      (":scheme", "https"),
      (":path", "/file/"),
      (":authority", "foo.bar"),
      ("user-agent", "HyperX/0.1"),
      ("content-type", "text/plain"),
      #("x-flow-control-check", "why_not"),
      ("x-cancel-remote", "foo")
    ],
    finish = false
  )
  let data = newStringRef newString(dataFrameLen)
  while true:  # until server cancel
    await strm.sendBody(data, finish = false)

proc recv(strm: ClientStream) {.async.} =
  var data = newStringref()
  await strm.recvHeaders(data)
  doAssert data[] == ":status: 200\r\n"
  data[].setLen 0
  while true:  # until server cancel
    await strm.recvBody(data)
    doAssert data[].len == 0

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
      doAssert err.typ == hxRemoteErr
      doAssert err.code == errCancel
    try:
      await sendFut
    except StrmError as err:
      doAssert err.typ == hxRemoteErr
      doAssert err.code == errCancel
    inc checked[]
    return

proc spawnStream(
  client: ClientContext,
  checked: ref int,
  sig: SignalAsync,
  inFlight: ref int
) {.async.} =
  try:
    await spawnStream(client, checked)
  finally:
    inFlight[] -= 1
    sig.trigger()

proc spawnClient(
  checked: ref int
) {.async.} =
  var client = newClient(localHost, localPort)
  with client:
    var stmsCount = 0
    var inFlight = new(int)
    inFlight[] = 0
    var sig = newSignal()
    while stmsCount < strmsPerClient:
      if not client.isConnected:
        return
      inFlight[] = inFlight[] + 1
      asyncCheck spawnStream(client, checked, sig, inFlight)
      inc stmsCount
      if stmsCount >= strmsPerClient:
        break
      if inFlight[] == strmsInFlight:
        await sig.waitFor()
    while inFlight[] > 0:
      await sig.waitFor()
    # XXX make server wait for all streams to end before exit conn
    await sleepAsync(5_000)

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
