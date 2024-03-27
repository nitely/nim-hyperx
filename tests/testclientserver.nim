{.define: ssl.}

import std/asyncdispatch
import pkg/hpack
import ../src/hyperx/client
import ../src/hyperx/server

template testAsync(name: string, body: untyped): untyped =
  (proc () = 
    echo "test " & name
    proc test() {.async.} =
      body
    waitFor test()
  )()

func newStringRef(): ref string =
  new result
  result[] = ""

const localPort = Port 4443
const localHost = "127.0.0.1"

testAsync "simple req/resp":
  proc doServerWork() {.async.} =
    let server = newServer(localHost, localPort)
    withServer server:
      let client = await server.recvClient()
      withClient client:
        let strm = await client.recvStream()
        withStream strm:
          let data = newStringref()
          await strm.recvHeaders(data)
          while not strm.recvEnded:
            await strm.recvBody(data)
          echo data[]
          data[] = "foobar body"
          await strm.sendHeaders(
            status = 200,
            contentType = "text/plain",
            contentLen = data[].len
          )
          await strm.sendBody(data, finish = true)
        await sleepAsync 4000

  proc doClientWork() {.async.} =
    var client = newClient(localHost, localPort)
    withConnection(client):
      let r = await client.get("/")
      echo r.headers
      echo r.text
      await sleepAsync 2000

  await (doServerWork() and doClientWork())
