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
  let shutdownSignal = newQueue[bool](1)
  var serverRecvHeaders = ""
  var serverRecvBody = ""
  proc doServerWork() {.async.} =
    let server = newServer(
      localHost, localPort, certFile, keyFile
    )
    with server:
      let client = await server.recvClient()
      with client:
        let strm = await client.recvStream()
        with strm:
          let data = newStringref()
          await strm.recvHeaders(data)
          serverRecvHeaders = data[]
          data[] = ""
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
        #await sleepAsync 4000
        discard await shutdownSignal.pop()

  var clientRecvHeaders = ""
  var clientRecvBody = ""
  proc doClientWork() {.async.} =
    var client = newClient(localHost, localPort)
    with client:
      let r = await client.get("/")
      clientRecvHeaders = r.headers
      clientRecvBody = r.text
      #await sleepAsync 2000

  var serverFut = doServerWork()
  var clientFut = doClientWork()
  await clientFut
  await shutdownSignal.put true
  await serverFut
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
  let shutdownSignal = newQueue[bool](1)
  var serverRecvStrm1 = ""
  var serverRecvStrm2 = ""
  proc processStreamServer(
    strm: ClientStream,
    dataIn, dataOut: ref string
  ) {.async.} =
    with strm:
      await strm.recvHeaders(dataIn)
      while not strm.recvEnded:
        await strm.recvBody(dataIn)
      await strm.sendHeaders(
        status = 200,
        contentType = "text/plain",
        contentLen = dataOut[].len
      )
      await strm.sendBody(dataOut, finish = true)
  proc doServerWork() {.async.} =
    let server = newServer(
      localHost, localPort, certFile, keyFile
    )
    with server:
      let client = await server.recvClient()
      with client:
        let dataIn1 = newStringref()
        let dataOut1 = newStringref("foobar 1")
        let dataIn2 = newStringref()
        let dataOut2 = newStringref("foobar 2")
        let strm1 = await client.recvStream()
        let strm1Fut = processStreamServer(strm1, dataIn1, dataOut1)
        let strm2 = await client.recvStream()
        let strm2Fut = processStreamServer(strm2, dataIn2, dataOut2)
        await strm1Fut and strm2Fut
        serverRecvStrm1 = dataIn1[]
        serverRecvStrm2 = dataIn2[]
        #await sleepAsync 4000
        discard await shutdownSignal.pop()

  let data1a = "foo"
  let data1b = "bar"
  let data2a = "baz"
  let data2b = "qux"
  let content = newStringRef()
  var clientRecvHeadersStrm1 = ""
  var clientRecvBodyStrm1 = ""
  var clientRecvHeadersStrm2 = ""
  var clientRecvBodyStrm2 = ""
  proc doClientWork() {.async.} =
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
          proc recv1() {.async.} =
            await strm1.recvHeaders(contentA)
            clientRecvHeadersStrm1 = contentA[]
            contentA[] = ""
            while not strm1.recvEnded:
              await strm1.recvBody(contentA)
            clientRecvBodyStrm1 = contentA[]
          let contentB = newStringRef()
          proc recv2() {.async.} =
            await strm2.recvHeaders(contentB)
            clientRecvHeadersStrm2 = contentB[]
            contentB[] = ""
            while not strm2.recvEnded:
              await strm2.recvBody(contentB)
            clientRecvBodyStrm2 = contentB[]
          await (recv1() and recv2())

  var serverFut = doServerWork()
  var clientFut = doClientWork()
  await clientFut
  await shutdownSignal.put true
  await serverFut
  doAssert serverRecvStrm1 ==
    ":method: POST\r\n" &
    ":scheme: https\r\n" &
    ":path: /foo\r\n" &
    ":authority: 127.0.0.1\r\n" &
    "user-agent: Nim-HyperX/0.1\r\n" &
    "content-type: application/json\r\n" &
    "content-length: 6\r\n" &
    "foobar"
  doAssert serverRecvStrm2 ==
    ":method: POST\r\n" &
    ":scheme: https\r\n" &
    ":path: /bar\r\n" &
    ":authority: 127.0.0.1\r\n" &
    "user-agent: Nim-HyperX/0.1\r\n" &
    "content-type: application/json\r\n" &
    "content-length: 6\r\n" &
    "bazqux"
