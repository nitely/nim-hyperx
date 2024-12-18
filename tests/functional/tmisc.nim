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
        var data = new string
        await strm2.recvHeaders(data)
        doAssert false
    except HyperxError:
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

testAsync "send after client graceful close":
  var checked = 0
  var client = newClient(localHost, localPort)
  with client:
    let strm = client.newClientStream()
    with strm:
      # This is not correct usage
      await client.gracefulClose()
      try:
        await strm.sendHeaders(defaultHeaders, finish = true)
        var data = new string
        await strm.recvHeaders(data)
      except HyperxConnError:
        #doAssert err.code == errNoError
        inc checked
    inc checked
  doAssert checked == 2
