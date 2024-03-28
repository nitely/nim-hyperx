{.define: ssl.}

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
  )()

func newStringRef(s = ""): ref string =
  new result
  result[] = s

const localPort = Port 4443
const localHost = "127.0.0.1"
# XXX this only works in my machine
const certFile = "/home/esteban/example.com+5.pem"
const keyFile = "/home/esteban/example.com+5-key.pem"

testAsync "simple req/resp":
  let shutdownSignal = newQueue[bool](1)
  var serverRecvHeaders = ""
  var serverRecvBody = ""
  proc doServerWork() {.async.} =
    let server = newServer(
      localHost, localPort, certFile, keyFile
    )
    withServer server:
      let client = await server.recvClient()
      withClient client:
        let strm = await client.recvStream()
        withStream strm:
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
    withClient client:
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
    "user-agent: Nim - HyperX\r\n" &
    "accept: */*\r\n"
  doAssert serverRecvBody == ""

testAsync "multiplex req/resp":
  let shutdownSignal = newQueue[bool](1)
  var serverRecvStrm1 = ""
  var serverRecvStrm2 = ""
  proc processStream(
    strm: server.ClientStream,
    dataIn, dataOut: ref string
  ) {.async.} =
    withStream strm:
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
    withServer server:
      let client = await server.recvClient()
      withClient client:
        let strm1 = await client.recvStream()
        let strm2 = await client.recvStream()
        let dataIn1 = newStringref()
        let dataOut1 = newStringref("foobar 1")
        let dataIn2 = newStringref()
        let dataOut2 = newStringref("foobar 2")
        await (
          processStream(strm1, dataIn1, dataOut1) and
          processStream(strm2, dataIn2, dataOut2)
        )
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
    withClient client:
      let strm1 = client.newClientStream()
      let strm2 = client.newClientStream()
      withStream strm1:
        withStream strm2:
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
          content[] = ""
          await strm1.recvHeaders(content)
          clientRecvHeadersStrm1 = content[]
          content[] = ""
          while not strm1.recvEnded:
            await strm1.recvBody(content)
          clientRecvBodyStrm1 = content[]
          content[] = ""
          await strm2.recvHeaders(content)
          clientRecvHeadersStrm2 = content[]
          content[] = ""
          while not strm2.recvEnded:
            await strm2.recvBody(content)
          clientRecvBodyStrm2 = content[]

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
    "user-agent: Nim - HyperX\r\n" &
    "content-type: application/json\r\n" &
    "content-length: 6\r\n" &
    "foobar"
  doAssert serverRecvStrm2 ==
    ":method: POST\r\n" &
    ":scheme: https\r\n" &
    ":path: /bar\r\n" &
    ":authority: 127.0.0.1\r\n" &
    "user-agent: Nim - HyperX\r\n" &
    "content-type: application/json\r\n" &
    "content-length: 6\r\n" &
    "bazqux"
