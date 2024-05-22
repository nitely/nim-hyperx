{.define: ssl.}

from std/os import getEnv
import std/strutils
import std/asyncdispatch
import ../../src/hyperx/server
import ./tutils

const certFile = getEnv "HYPERX_TEST_CERTFILE"
const keyFile = getEnv "HYPERX_TEST_KEYFILE"

proc processStream(strm: ClientStream) {.async.} =
  withStream strm:
    var dataEcho = newStringRef()
    await strm.recvHeaders(dataEcho)
    while not strm.recvEnded:
      await strm.recvBody(dataEcho)
    await strm.sendHeaders(
      status = 200,
      contentType = "text/plain",
      contentLen = dataEcho[].len
    )
    if dataEcho[].len > 0:
      await strm.sendBody(dataEcho, finish = true)
  #GC_fullCollect()

proc processStreamHandler(strm: ClientStream) {.async.} =
  try:
    await processStream(strm)
  except HyperxStrmError as err:
    debugEcho err.msg
  except HyperxConnError as err:
    debugEcho err.msg

proc processClient(client: ClientContext) {.async.} =
  withClient client:
    while client.isConnected:
      let strm = await client.recvStream()
      asyncCheck processStreamHandler(strm)

proc processClientHandler(client: ClientContext) {.async.} =
  try:
    await processClient(client)
  except HyperxConnError as err:
    debugEcho err.msg
  when defined(hyperxStats):
    echoStats client

proc serve(server: ServerContext) {.async.} =
  withServer server:
    while server.isConnected:
      let client = await server.recvClient()
      asyncCheck processClientHandler(client)

proc newServer(): ServerContext =
  newServer(
    localHost, localPort, certFile, keyFile
  )

when isMainModule:
  proc main() {.async.} =
    echo "Serving forever"
    var server = newServer()
    await server.serve()
  waitFor main()
  doAssert not hasPendingOperations()
  echo "ok"
