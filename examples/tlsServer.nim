## TLS echo server

{.define: ssl.}

from std/os import getEnv
import std/asyncdispatch
import ../src/hyperx/server

const localHost* = "127.0.0.1"
const localPort* = Port 8783
const certFile = getEnv "HYPERX_TEST_CERTFILE"
const keyFile = getEnv "HYPERX_TEST_KEYFILE"

proc processStream(stream: ClientStream) {.async.} =
  ## Echo stream
  let data = new string
  await stream.recvHeaders(data)
  await stream.sendHeaders(
    @[(":status", "200")], finish = false
  )
  while not stream.recvEnded:
    data[].setLen 0
    await stream.recvBody(data)
    await stream.sendBody(data, finish = false)
  data[].setLen 0
  await stream.sendBody(data, finish = true)

proc main() {.async.} =
  echo "Serving forever"
  let server = newServer(
    localHost, localPort, certFile, keyFile
  )
  await server.serve(processStream)

when isMainModule:
  waitFor main()
  echo "ok"
