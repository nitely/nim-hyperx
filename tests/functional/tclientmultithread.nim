{.define: ssl.}
{.define: hyperxSanityCheck.}

import std/asyncdispatch
import ../../src/hyperx/client
import ../../src/hyperx/limiter
import ./tutils.nim

const strmsPerClient = 61
const clientsCount = 61
const strmsInFlight = 100
const dataFrameLen = 61
const theData = newString(dataFrameLen)

proc send(strm: ClientStream) {.async.} =
  await strm.sendHeaders(
    @[
      (":method", "POST"),
      (":scheme", "https"),
      (":path", "/file/"),
      (":authority", "foo.bar"),
      ("user-agent", "HyperX/0.1"),
      ("content-type", "text/plain"),
      ("x-no-echo-headers", "true")
    ],
    finish = false
  )
  let data = newStringRef theData & $strm.stream.id.int
  await strm.sendBody(data, finish = true)

proc recv(strm: ClientStream) {.async.} =
  var data = newStringref()
  await strm.recvHeaders(data)
  doAssert data[] == ":status: 200\r\n"
  data[].setLen 0
  while not strm.recvEnded:
    await strm.recvBody(data)
  doAssert data[] == theData & $strm.stream.id.int

proc spawnStream(
  client: ClientContext,
  checked: ref int
) {.async.} =
  let strm = client.newClientStream()
  with strm:
    let sendFut = strm.send()
    let recvFut = strm.recv()
    await recvFut
    await sendFut
    inc checked[]

proc spawnClient(
  checked: ref int
) {.async.} =
  var client = newClient(localHost, localMultiThreadPort)
  with client:
    let lt = newLimiter(strmsInFlight)
    for _ in 0 .. strmsPerClient-1:
      if not client.isConnected:
        return
      await lt.spawn spawnStream(client, checked)
    await lt.join()

proc main(checked: ref int) {.async.} =
  var clients = newSeq[Future[void]]()
  for _ in 0 .. clientsCount-1:
    clients.add spawnClient(checked)
  for clientFut in clients:
    await clientFut

proc worker(result: ptr int) {.thread.} =
  let checked = new(int)
  checked[] = 0
  waitFor main(checked)
  doAssert not hasPendingOperations()
  setGlobalDispatcher(nil)
  destroyClientSslContext()
  result[] = checked[]

proc run =
  var threads = newSeq[Thread[ptr int]](4)
  var results = newSeq[int](threads.len)
  for i in 0 .. threads.len-1:
    createThread(threads[i], worker, addr results[i])
  for i in 0 .. threads.len-1:
    joinThread(threads[i])
  for checked in results:
    doAssert checked == clientsCount * strmsPerClient
    echo "checked ", $checked

(proc =
  run()
  echo "ok"
)()
