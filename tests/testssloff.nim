# just check this compiles without -d:ssl

import std/asyncdispatch
import ../src/hyperx/server
import ../src/hyperx/client

const localHost = "127.0.0.1"
const localPort = Port 8783
discard newServer(localHost, localPort, ssl = false)
discard newClient(localHost, localPort, ssl = false)

template sslServer: untyped =
  discard newServer(localHost, localPort, ssl = true)
template sslClient: untyped =
  discard newClient(localHost, localPort, ssl = true)
static:
  doAssert not compiles(sslServer)
  doAssert not compiles(sslClient)
  echo "ok"

doAssert false  # do not run this file
