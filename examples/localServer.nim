## Echo server

{.define: ssl.}

from std/os import getEnv
import std/strutils
import std/asyncdispatch
import ../src/hyperx/server

const localHost* = "/tmp/hyperxasd22.sock"
const localPort* = Port 0
const certFile = getEnv "HYPERX_TEST_CERTFILE"
const keyFile = getEnv "HYPERX_TEST_KEYFILE"

func newStringRef(s = ""): ref string =
  new result
  result[] = s

func newSeqRef[T](s: seq[T] = @[]): ref seq[T] =
  new result
  result[] = s

proc processStream(strm: ClientStream) {.async.} =
  ## Full-duplex echo stream
  with strm:
    let data = newStringRef()
    await strm.recvHeaders(data)
    await strm.sendHeaders(
      newSeqRef(@[(":status", "200")]),
      finish = false
    )
    if strm.recvEnded:
      data[] = "Hello world!"
      await strm.sendBody(data, finish = true)
    while not strm.recvEnded:
      data[].setLen 0
      await strm.recvBody(data)
      await strm.sendBody(data, finish = strm.recvEnded)
    if not strm.sendEnded:
      # recv ended while sending; trailer headers or empty data recv
      data[].setLen 0
      await strm.sendBody(data, finish = true)

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
  with client:
    while client.isConnected:
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
  with server:
    while server.isConnected:
      let client = await server.recvClient()
      asyncCheck processClientHandler(client, propagateErr)

proc newServer*(): ServerContext =
  newServer(
    localHost, localPort, certFile, keyFile, ssl = false, domain = hyxUnix
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
