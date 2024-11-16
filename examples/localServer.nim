## Echo server

{.define: ssl.}

from std/os import getEnv
from std/asyncdispatch import Port, waitFor
import pkg/yasync
import pkg/yasync/compat
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
    @[(":status", "200")], finish = true
  )
  #if strm.recvEnded:
  #  data[] = "Hello world!"
  #  await strm.sendBody(data, finish = true)
  while not strm.recvEnded:
    data[].setLen 0
    await strm.recvBody(data)
  #  await strm.sendBody(data, finish = strm.recvEnded)
  #if not strm.sendEnded:
  #  # recv ended while sending; trailer headers or empty data recv
  #  data[].setLen 0
  #  await strm.sendBody(data, finish = true)

proc processStreamHandler(
  strm: ClientStream
) {.async.} =
  try:
    with strm:
      await processStream(strm)
  except HyperxError:
    #debugInfo getCurrentException().getStackTrace()
    #debugInfo getCurrentException().msg
    discard

proc processClientHandler(
  client: ClientContext
) {.async.} =
  try:
    with client:
      while client.isConnected:
        let strm = await client.recvStream()
        discard processStreamHandler(strm)
  except HyperxError:
    #debugInfo getCurrentException().getStackTrace()
    #debugInfo getCurrentException().msg
    discard

proc serve2(
  server: ServerContext
) {.async.} =
  with server:
    while server.isConnected:
      let client = await server.recvClient()
      discard processClientHandler(client)

proc main() {.async.} =
  echo "Serving forever"
  let server = newServer(
    localHost, localPort, certFile, keyFile, ssl = false
  )
  await serve2(server)

when isMainModule:
  waitFor main()
  echo "ok"
