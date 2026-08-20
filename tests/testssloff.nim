# just check this compiles without -d:ssl

import std/asyncdispatch
import std/net
when defined(posix):
  import std/posix
import ../src/hyperx/server
import ../src/hyperx/client

const localHost = "127.0.0.1"
const localPort = Port 8783
discard newServer(localHost, localPort, ssl = false)
discard newClient(localHost, localPort, ssl = false)
discard newServer("::1", localPort, ssl = false, domain = Domain.AF_INET6)
discard newClient("::1", localPort, ssl = false, domain = Domain.AF_INET6)
when defined(posix):
  discard newServerUnix("/tmp/hyperx.sock", 0o660.Mode)
  discard newClientUnix("/tmp/hyperx.sock")

template sslServer: untyped =
  discard newServer(localHost, localPort, ssl = true)
template sslClient: untyped =
  discard newClient(localHost, localPort, ssl = true)
static:
  doAssert not compiles(sslServer)
  doAssert not compiles(sslClient)
  echo "ok"

doAssert false  # do not run this file
