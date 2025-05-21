## Echo server

{.define: ssl.}

from std/os import getEnv
import std/asyncdispatch
import ../src/hyperx/server

const localHost* = "127.0.0.1"
const localPort* = Port 8783
const certFile = getEnv "HYPERX_TEST_CERTFILE"
const keyFile = getEnv "HYPERX_TEST_KEYFILE"

proc processStream(strm: ClientStream) {.async.} =
  ## Full-duplex echo stream
  let data = new string
  await strm.recvHeaders(data)
  await strm.sendHeaders(
    @[(":status", "200")], finish = false
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

proc main() {.async.} =
  echo "Serving forever"
  let server = newServer(
    localHost, localPort, certFile, keyFile
  )
  await server.serve(processStream)

run2(
  localHost, localPort, processStream, threads = 8 #, ssl = false
)

#when isMainModule:
#  waitFor main()
#  echo "ok"
