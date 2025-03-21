{.define: ssl.}
{.define: hyperxSanityCheck.}

from std/os import getEnv
from std/strutils import contains
import std/asyncdispatch
import ../../src/hyperx/server
import ./tutils
from ../../src/hyperx/errors import hyxCancel

const certFile = getEnv "HYPERX_TEST_CERTFILE"
const keyFile = getEnv "HYPERX_TEST_KEYFILE"

proc processStream*(strm: ClientStream) {.async.} =
  let headers = strm.headersRecv()
  let data = newStringRef headers
  if "x-flow-control-check" in headers:
    # let recv buff for a bit
    #debugEcho "sleeping"
    await sleepAsync(10_000)
  await strm.sendHeaders(
    @[(":status", "200")], finish = false
  )
  if "x-cancel-remote" in headers:
    # do not return here, let it raise when sendBody is called
    await strm.sendHeaders(
      @[("x-trailer", "bye")], finish = true
    )
    await strm.cancel(hyxCancel)
  if "x-graceful-close-remote" in headers:
    await strm.client.gracefulClose()
  if "x-no-echo-headers" notin headers:
    await strm.sendBody(data, finish = strm.recvEnded)
  while not strm.recvEnded:
    data[].setLen 0
    await strm.recvBody(data)
    await strm.sendBody(data, finish = strm.recvEnded)
  if not strm.sendEnded:
    data[].setLen 0
    await strm.sendBody(data, finish = true)
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
