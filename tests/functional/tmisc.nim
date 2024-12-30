{.define: ssl.}

# make tmisc2.nim if this is needed
#{.define: hyperxSanityCheck.}

import std/asyncdispatch
from ../../src/hyperx/server import gracefulClose
import ../../src/hyperx/client
import ../../src/hyperx/errors
import ./tutils.nim

template testAsync(name: string, body: untyped): untyped =
  (proc () =
    echo "test " & name
    var checked = false
    proc test {.async.} =
      body
      checked = true
    waitFor test()
    doAssert not hasPendingOperations()
    doAssert checked
  )()

proc sleepCycle: Future[void] =
  let fut = newFuture[void]()
  proc wakeup = fut.complete()
  callSoon wakeup
  return fut

const defaultHeaders = @[
  (":method", "POST"),
  (":scheme", "https"),
  (":path", "/foo"),
  (":authority", "foo.bar"),
  ("user-agent", "HyperX/0.1"),
  ("content-type", "text/plain")
]

testAsync "cancel many times":
  var checked = 0
  var client = newClient(localHost, localPort)
  with client:
    let strm = client.newClientStream()
    with strm:
      await strm.sendHeaders(defaultHeaders, finish = false)
      var data = new string
      await strm.recvHeaders(data)
      doAssert data[] == ":status: 200\r\n"
      await strm.cancel(hyxCancel)
      await strm.cancel(hyxCancel)
      inc checked
    inc checked
  doAssert checked == 2

testAsync "cancel concurrently":
  var checked = 0
  var client = newClient(localHost, localPort)
  with client:
    let strm = client.newClientStream()
    with strm:
      await strm.sendHeaders(defaultHeaders, finish = false)
      var data = new string
      await strm.recvHeaders(data)
      doAssert data[] == ":status: 200\r\n"
      let fut1 = strm.cancel(hyxCancel)
      let fut2 = strm.cancel(hyxCancel)
      await fut1
      await fut2
      inc checked
    inc checked
  doAssert checked == 2

testAsync "cancel task":
  var checked = 0
  var client = newClient(localHost, localPort)
  var cancelFut = default(Future[void])
  with client:
    let strm = client.newClientStream()
    with strm:
      await strm.sendHeaders(defaultHeaders, finish = false)
      var data = new string
      await strm.recvHeaders(data)
      doAssert data[] == ":status: 200\r\n"
      cancelFut = strm.cancel(hyxCancel)
      await strm.cancel(hyxCancel)
      inc checked
    inc checked
  await cancelFut
  doAssert checked == 2

testAsync "server graceful close":
  var checked = 0
  var client = newClient(localHost, localPort)
  with client:
    let strm = client.newClientStream()
    with strm:
      var headers = defaultHeaders
      headers.add ("x-no-echo-headers", "true")
      headers.add ("x-graceful-close-remote", "true")
      await strm.sendHeaders(headers, finish = false)
      var data = new string
      await strm.recvHeaders(data)
      doAssert data[] == ":status: 200\r\n"
      data[] = "foobar"
      await strm.sendBody(data, finish = true)
      data[] = ""
      await strm.recvBody(data)
      doAssert data[] == "foobar"
      inc checked
    try:
      discard client.newClientStream()
    except GracefulShutdownError:
      inc checked
  doAssert checked == 2

# XXX cannot longer check server is sending GoAway
#     since cannot create a stream before sending headers
testAsync "send after server graceful close":
  var checked = 0
  var client = newClient(localHost, localPort)
  with client:
    # This is not correct usage
    let strm = client.newClientStream()
    let strm2 = client.newClientStream()
    with strm:
      var headers = defaultHeaders
      headers.add ("x-graceful-close-remote", "true")
      await strm.sendHeaders(headers, finish = true)
      var data = new string
      await strm.recvHeaders(data)
      doAssert data[] == ":status: 200\r\n"
      await strm.recvBody(data)
      inc checked
    # XXX doAssert strm2.isClosed
    try:
      with strm2:
        await strm2.sendHeaders(defaultHeaders, finish = true)
        doAssert false
    except GracefulShutdownError:
      inc checked
  doAssert checked == 2

testAsync "client graceful close":
  # in practice just stop creating streams
  # and close normally at the end
  var checked = 0
  var client = newClient(localHost, localPort)
  with client:
    let strm = client.newClientStream()
    with strm:
      var headers = defaultHeaders
      headers.add ("x-no-echo-headers", "true")
      #headers.add ("x-graceful-close-remote", "true")
      await strm.sendHeaders(headers, finish = false)
      var data = new string
      await strm.recvHeaders(data)
      doAssert data[] == ":status: 200\r\n"
      await client.gracefulClose()
      data[] = "foobar"
      await strm.sendBody(data, finish = true)
      data[] = ""
      await strm.recvBody(data)
      doAssert data[] == "foobar"
      inc checked
    try:
      discard client.newClientStream()
    except GracefulShutdownError:
      inc checked
  doAssert checked == 2

# XXX cannot longer create a stream before shutdown
#     and send on it after because of lazy stream id
testAsync "send after client graceful close":
  var checked = 0
  var client = newClient(localHost, localPort)
  with client:
    let strm = client.newClientStream()
    await client.gracefulClose()
    try:
      with strm:
        await strm.sendHeaders(defaultHeaders, finish = true)
        doAssert false
    except GracefulShutdownError:
      inc checked
  doAssert checked == 1

testAsync "lazy client stream id":
  var order = new seq[int]
  order[] = newSeq[int]()
  var checked = new int
  checked[] = 0
  proc stream(client: ClientContext, sleep = 0) {.async.} =
    let strm = client.newClientStream()
    with strm:
      for i in 0 .. sleep-1:
        await sleepCycle()
        #echo $sleep
      order[].add sleep
      var headers = defaultHeaders
      headers.add ("x-no-echo-headers", "true")
      await strm.sendHeaders(headers, finish = false)
      var data = new string
      await strm.recvHeaders(data)
      doAssert data[] == ":status: 200\r\n"
      data[] = "foobar" & $sleep
      await strm.sendBody(data, finish = true)
      data[] = ""
      await strm.recvBody(data)
      doAssert data[] == "foobar" & $sleep
      checked[] += 1
    checked[] += 1
  var client = newClient(localHost, localPort)
  with client:
    let strm1 = client.stream(200)
    let strm2 = client.stream(100)
    await strm1
    await strm2
    doAssert order[] == @[100, 200]
    checked[] += 1
  doAssert checked[] == 5
