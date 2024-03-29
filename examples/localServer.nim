{.define: ssl.}

import std/strutils
import std/asyncdispatch
import ../src/hyperx/server

const localHost* = "127.0.0.1"
const localPort* = Port 4443
# XXX this only works in my machine
#     make it work in docker
const certFile = "/home/esteban/example.com+5.pem"
const keyFile = "/home/esteban/example.com+5-key.pem"

func newStringRef(s = ""): ref string =
  new result
  result[] = s

proc processStream(strm: ClientStream) {.async.} =
  ## This receives the headers & body from a stream
  ## opened by the client, and sends back whatever
  ## data it received. It's an echo server.
  withStream strm:
    var headers = newStringRef()
    await strm.recvHeaders(headers)
    doAssert ":authority: " & localHost in headers[]
    var dataEcho = newStringRef()
    while not strm.recvEnded:
      await strm.recvBody(dataEcho)
    if dataEcho[].len == 0:
      dataEcho[] = "Hello world!"
    await strm.sendHeaders(
      status = 200,
      contentType = "text/plain",
      contentLen = dataEcho[].len
    )
    await strm.sendBody(dataEcho, finish = true)

proc processClient(client: ClientContext) {.async.} =
  withClient client:
    while client.isConnected:
      let strm = await client.recvStream()
      asyncCheck processStream(strm)

proc serve*(server: ServerContext) {.async.} =
  withServer server:
    while server.isConnected:
      let client = await server.recvClient()
      asyncCheck processClient(client)

proc newServer*(): ServerContext =
  newServer(
    localHost, localPort, certFile, keyFile
  )

when isMainModule:
  proc main() {.async.} =
    echo "Serving forever"
    var server = newServer()
    await server.serve()
  waitFor main()
  echo "ok"
