{.define: ssl.}

from std/os import getEnv
import std/strutils
import yasync
import yasync/compat
from std/asyncdispatch import Port, waitFor
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
  ## data it received (up to 16KB). It's an echo server.
  withStream strm:
    var headers = newStringRef()
    await strm.recvHeaders(headers)
    #doAssert ":authority: " & localHost in headers[]
    var dataEcho = newStringRef()
    while not strm.recvEnded:
      await strm.recvBody(dataEcho)
      if dataEcho[].len >= (16 * 1024)-1:
        dataEcho[].setLen 0
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
    while client.isConnected:
      let strm = await client.recvStream()
      discard processStreamHandler(strm, propagateErr)

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
    while server.isConnected:
      let client = await server.recvClient()
      discard processClientHandler(client, propagateErr)

proc newServer*(): ServerContext =
  newServer(
    localHost, localPort, certFile, keyFile
  )

when isMainModule:
  proc main() {.async.} =
    echo "Serving forever"
    var server = newServer()
    await server.serve(propagateErr = false)
  when true:
    waitFor main()
  else:  # this is better for profiling/benchmarking but uses 100% CPU
    var fut = main()
    while not fut.finished:
      poll(0)
    fut.read()
  echo "ok"
