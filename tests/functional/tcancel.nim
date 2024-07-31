{.define: ssl.}
{.define: hyperxSanityCheck.}

import std/asyncdispatch
import ../../src/hyperx/client
import ../../src/hyperx/signal
import ../../src/hyperx/errors
import ./tutils.nim
from ../../src/hyperx/clientserver import stgWindowSize

const strmsPerClient = 1123
const clientsCount = 25
const strmsInFlight = 100
const dataPayloadLen = stgWindowSize.int * 2 + 123

proc send(strm: ClientStream) {.async.} =
  await strm.sendHeaders(
    newSeqRef(@[
      (":method", "POST"),
      (":scheme", "https"),
      (":path", "/file/"),
      (":authority", "foo.bar"),
      ("user-agent", "HyperX/0.1"),
      ("content-type", "text/plain")
    ]),
    finish = false
  )
  var sentBytes = 0
  var data = newStringRef newString(16 * 1024 + 123)
  while sentBytes < dataPayloadLen:
    await strm.sendBody(data, finish = false)
    sentBytes += data[].len
  await strm.sendBody(data, finish = true)

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
    let recvFut = strm.recv()
    let sendFut = strm.send()
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
      inFlight[] = inFlight[] + 1
      asyncCheck spawnStream(client, checked, sig, inFlight)
      inc stmsCount
      if stmsCount >= strmsPerClient:
        break
      if inFlight[] == strmsInFlight:
        await sig.waitFor()
    while inFlight[] > 0:
      await sig.waitFor()

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
