{.define: ssl.}

from std/os import getEnv
import std/asyncdispatch
import ../../src/hyperx/server
import ./tutils

const certFile = getEnv "HYPERX_TEST_CERTFILE"
const keyFile = getEnv "HYPERX_TEST_KEYFILE"

proc processStream(strm: ClientStream) {.async.} =
  withStream strm:
    let data = newStringRef()
    await strm.recvHeaders(data)
    await strm.sendHeaders(
      newSeqRef(@[(":status", "200")]),
      finish = false
    )
    await strm.sendBody(data, finish = strm.recvEnded)
    while not strm.recvEnded:
      data[].setLen 0
      await strm.recvBody(data)
      await strm.sendBody(data, finish = strm.recvEnded)
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
