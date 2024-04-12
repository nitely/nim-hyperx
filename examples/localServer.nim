{.define: ssl.}

from std/os import getEnv
import std/strutils
import std/asyncdispatch
import ../src/hyperx/server

const localHost* = "127.0.0.1"
const localPort* = Port 4443
const certFile = getEnv "HYPERX_TEST_CERTFILE"
const keyFile = getEnv "HYPERX_TEST_KEYFILE"

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

proc processStreamHandler(strm: ClientStream, propagateErr: bool) {.async.} =
  try:
    await processStream(strm)
  except HyperxStrmError as err:
    if propagateErr:
      raise err
    debugEcho err.msg
  except HyperxConnError as err:
    if propagateErr:
      raise err
    debugEcho err.msg

proc processClient(client: ClientContext, propagateErr: bool) {.async.} =
  withClient client:
    while true:
      let strm = await client.recvStream()
      asyncCheck processStreamHandler(strm, propagateErr)

proc processClientHandler(client: ClientContext, propagateErr: bool) {.async.} =
  try:
    await processClient(client, propagateErr)
  except HyperxConnError as err:
    if propagateErr:
      raise err
    debugEcho err.msg

# xxx propagateErr = false
proc serve*(server: ServerContext, propagateErr = true) {.async.} =
  withServer server:
    while true:
      let client = await server.recvClient()
      asyncCheck processClientHandler(client, propagateErr)

proc newServer*(): ServerContext =
  newServer(
    localHost, localPort, certFile, keyFile
  )

when isMainModule:
  proc main() {.async.} =
    echo "Serving forever"
    var server = newServer()
    await server.serve(propagateErr = false)
  waitFor main()
  echo "ok"
