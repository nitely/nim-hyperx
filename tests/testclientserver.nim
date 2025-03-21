{.define: ssl.}
{.define: hyperxSanityCheck.}

from os import getEnv
import std/asyncdispatch
import ../src/hyperx/client
import ../src/hyperx/server
import ../src/hyperx/queue

template testAsync(name: string, body: untyped): untyped =
  (proc () = 
    echo "test " & name
    proc test() {.async.} =
      body
    discard getGlobalDispatcher()
    waitFor test()
    doAssert not hasPendingOperations()
    when false:
      setGlobalDispatcher(nil)
      GC_fullCollect()
  )()

func newStringRef(s = ""): ref string =
  new result
  result[] = s

const localPort = Port 8773
const localHost = "127.0.0.1"
const certFile = getEnv "HYPERX_TEST_CERTFILE"
const keyFile = getEnv "HYPERX_TEST_KEYFILE"

testAsync "simple req/resp":
  var serverRecvHeaders = ""
  var serverRecvBody = ""
  proc processStream(strm: ClientStream) {.async.} =
    serverRecvHeaders = strm.headersRecv()
    let data = newStringref()
    while not strm.recvEnded:
      await strm.recvBody(data)
    serverRecvBody = data[]
    data[] = "foobar body"
    await strm.sendHeaders(
      status = 200,
      contentType = "text/plain",
      contentLen = data[].len
    )
    await strm.sendBody(data, finish = true)
  let server = newServer(
    localHost, localPort, certFile, keyFile
  )
  let serverFut = server.serve(processStream)
  var clientRecvHeaders = ""
  var clientRecvBody = ""
  let client = newClient(localHost, localPort)
  with client:
    let r = await client.get("/")
    clientRecvHeaders = r.headers
    clientRecvBody = r.text
  server.close()
  try:
    await serverFut
    doAssert false
  except HyperxConnError:
    doAssert true
  doAssert clientRecvHeaders ==
    ":status: 200\r\n" &
    "content-type: text/plain\r\n" &
    "content-length: 11\r\n"
  doAssert clientRecvBody == "foobar body"
  doAssert serverRecvHeaders ==
    ":method: GET\r\n" &
    ":scheme: https\r\n" &
    ":path: /\r\n" &
    ":authority: 127.0.0.1\r\n" &
    "user-agent: Nim-HyperX/0.1\r\n" &
    "accept: */*\r\n"
  doAssert serverRecvBody == ""

testAsync "multiplex req/resp":
  var serverRecv = newSeq[ref string]()
  proc processStream(strm: ClientStream) {.async.} =
    var dataIn = newStringref()
    serverRecv.add dataIn
    let headers = strm.headersRecv()
    dataIn.add headers
    while not strm.recvEnded:
      await strm.recvBody(dataIn)
    var dataOut = newStringref("foo")
    await strm.sendHeaders(
      status = 200,
      contentType = "text/plain",
      contentLen = dataOut[].len
    )
    await strm.sendBody(dataOut, finish = true)
  let server = newServer(
    localHost, localPort, certFile, keyFile
  )
  let serverFut = server.serve(processStream)

  let data1a = "foo"
  let data1b = "bar"
  let data2a = "baz"
  let data2b = "qux"
  let content = newStringRef()
  var clientRecvHeadersStrm1 = ""
  var clientRecvBodyStrm1 = ""
  var clientRecvHeadersStrm2 = ""
  var clientRecvBodyStrm2 = ""
  var client = newClient(localHost, localPort)
  with client:
    let strm1 = client.newClientStream()
    let strm2 = client.newClientStream()
    with strm1:
      with strm2:
        await strm1.sendHeaders(
          hmPost, "/foo",
          contentLen = data1a.len+data1b.len
        )
        await strm2.sendHeaders(
          hmPost, "/bar",
          contentLen = data2a.len+data2b.len
        )
        content[] = data1a
        await strm1.sendBody(content)
        content[] = data2a
        await strm2.sendBody(content)
        content[] = data1b
        await strm1.sendBody(content, finish = true)
        content[] = data2b
        await strm2.sendBody(content, finish = true)
        let contentA = newStringRef()
        await strm1.recvHeaders(contentA)
        clientRecvHeadersStrm1 = contentA[]
        contentA[] = ""
        while not strm1.recvEnded:
          await strm1.recvBody(contentA)
        clientRecvBodyStrm1 = contentA[]
        let contentB = newStringRef()
        await strm2.recvHeaders(contentB)
        clientRecvHeadersStrm2 = contentB[]
        contentB[] = ""
        while not strm2.recvEnded:
          await strm2.recvBody(contentB)
        clientRecvBodyStrm2 = contentB[]
  server.close()
  try:
    await serverFut
    doAssert false
  except HyperxConnError:
    doAssert true
  doAssert serverRecv[0][] ==
    ":method: POST\r\n" &
    ":scheme: https\r\n" &
    ":path: /foo\r\n" &
    ":authority: 127.0.0.1\r\n" &
    "user-agent: Nim-HyperX/0.1\r\n" &
    "content-type: application/json\r\n" &
    "content-length: 6\r\n" &
    "foobar"
  doAssert serverRecv[1][] ==
    ":method: POST\r\n" &
    ":scheme: https\r\n" &
    ":path: /bar\r\n" &
    ":authority: 127.0.0.1\r\n" &
    "user-agent: Nim-HyperX/0.1\r\n" &
    "content-type: application/json\r\n" &
    "content-length: 6\r\n" &
    "bazqux"
