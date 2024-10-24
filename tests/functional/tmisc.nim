{.define: ssl.}
{.define: hyperxSanityCheck.}

import std/asyncdispatch
import ../../src/hyperx/client
import ../../src/hyperx/errors
import ./tutils.nim

template testAsync(name: string, body: untyped): untyped =
  (proc () = 
    echo "test " & name
    var checked = false
    proc test() {.async.} =
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
    try:
      with strm:
        await strm.sendHeaders(defaultHeaders, finish = false)
        var data = new string
        await strm.recvHeaders(data)
        doAssert data[] == ":status: 200\r\n"
        await strm.cancel(errCancel)
        await strm.cancel(errCancel)
        inc checked
        # XXX remove
        raise newException(ValueError, "foo")
    # XXX change with sendEnded/recvEnded to stream status check
    except ValueError as err:
      doAssert err.msg == "foo"
  doAssert checked == 1

testAsync "cancel concurrently":
  var checked = 0
  var client = newClient(localHost, localPort)
  with client:
    let strm = client.newClientStream()
    try:
      with strm:
        await strm.sendHeaders(defaultHeaders, finish = false)
        var data = new string
        await strm.recvHeaders(data)
        doAssert data[] == ":status: 200\r\n"
        let fut1 = strm.cancel(errCancel)
        let fut2 = strm.cancel(errCancel)
        await fut1
        await fut2
        inc checked
        # XXX remove
        raise newException(ValueError, "foo")
    # XXX change with sendEnded/recvEnded to stream status check
    except ValueError as err:
      doAssert err.msg == "foo"
  doAssert checked == 1

testAsync "cancel task":
  var checked = 0
  var client = newClient(localHost, localPort)
  var cancelFut: Future[void]
  with client:
    let strm = client.newClientStream()
    try:
      with strm:
        await strm.sendHeaders(defaultHeaders, finish = false)
        var data = new string
        await strm.recvHeaders(data)
        doAssert data[] == ":status: 200\r\n"
        cancelFut = strm.cancel(errCancel)
        await strm.cancel(errCancel)
        inc checked
        # XXX remove
        raise newException(ValueError, "foo")
    # XXX change with sendEnded/recvEnded to stream status check
    except ValueError as err:
      doAssert err.msg == "foo"
  await cancelFut
  doAssert checked == 1
