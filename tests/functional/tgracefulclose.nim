{.define: ssl.}
{.define: hyperxSanityCheck.}

import std/asyncdispatch
import ../../src/hyperx/client
import ../../src/hyperx/limiter
#import ../../src/hyperx/errors
import ./tutils.nim
from ../../src/hyperx/clientserver import stgWindowSize

# Since this relies on a sleep, it can be flaky
# but if it fails, there's something wrong;
# it's just hard to make it consistenly fail;
# checked output should be a fairly random number;
# output like "checked 5000" (clients*streams) means streams are not
# created in between server receiving the posion pill
# and client ACK'ing the ping

const clientsCount = 50
const strmsInFlight = 100
const dataFrameLen = 123
#const dataFrameLen = stgWindowSize.int * 2 + 123
const theData = newString(dataFrameLen)

proc send(strm: ClientStream, poison = false) {.async.} =
  var headers = @[
    (":method", "POST"),
    (":scheme", "https"),
    (":path", "/file/"),
    (":authority", "foo.bar"),
    ("user-agent", "HyperX/0.1"),
    ("content-type", "text/plain"),
    ("x-no-echo-headers", "true")
  ]
  if poison:
    headers.add ("x-graceful-close-remote", "true")
  await strm.sendHeaders(headers, finish = false)
  # cannot sleep before sending headers
  if poison:
    await sleepAsync(10_000)
  let data = newStringref theData & $strm.stream.id.int
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
  checked: ref int,
  poison = false
) {.async.} =
  if poison:
    await sleepAsync(10_000)
  if client.isGracefulClose:
    inc checked[]
    return
  let strm = client.newClientStream()
  with strm:
    let sendFut = strm.send(poison)
    let recvFut = strm.recv()
    await recvFut
    await sendFut
    inc checked[]

proc spawnClient(
  checked: ref int
) {.async.} =
  var client = newClient(localHost, localPort)
  with client:
    let lt = newLimiter(strmsInFlight)
    await lt.spawn spawnStream(client, checked, poison = true)
    while not client.isGracefulClose:
      doAssert client.isConnected
      await lt.spawn spawnStream(client, checked)
    await lt.join()

proc main() {.async.} =
  let checked = new(int)
  checked[] = 0
  var clients = newSeq[Future[void]]()
  for _ in 0 .. clientsCount-1:
    clients.add spawnClient(checked)
  for clientFut in clients:
    await clientFut
  doAssert checked[] >= clientsCount #* strmsInFlight
  echo "checked ", $checked[]

(proc =
  waitFor main()
  doAssert not hasPendingOperations()
  echo "ok"
)()
