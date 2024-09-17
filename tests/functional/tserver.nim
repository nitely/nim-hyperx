{.define: ssl.}
{.define: hyperxSanityCheck.}

from std/os import getEnv
from std/strutils import contains
import std/asyncdispatch
import ../../src/hyperx/server
import ./tutils

const certFile = getEnv "HYPERX_TEST_CERTFILE"
const keyFile = getEnv "HYPERX_TEST_KEYFILE"

proc processStream(strm: ClientStream) {.async.} =
  let data = new string
  await strm.recvHeaders(data)
  if "x-flow-control-check" in data[]:
    # let recv buff for a bit
    #debugEcho "sleeping"
    await sleepAsync(10_000)
  await strm.sendHeaders(
    @[(":status", "200")], finish = false
  )
  await strm.sendBody(data, finish = strm.recvEnded)
  while not strm.recvEnded:
    data[].setLen 0
    await strm.recvBody(data)
    await strm.sendBody(data, finish = strm.recvEnded)
  #GC_fullCollect()

proc serve*(server: ServerContext) {.async.} =
  await server.serve(processStream)

proc main() {.async.} =
  echo "Serving forever"
  var server = newServer(
    localHost, localPort, certFile, keyFile
  )
  await server.serve()

when isMainModule:
  waitFor main()
  doAssert not hasPendingOperations()
  echo "ok"
