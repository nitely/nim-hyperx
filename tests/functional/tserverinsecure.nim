{.define: ssl.}
{.define: hyperxSanityCheck.}
{.define: hyperxLetItCrash.}

import std/asyncdispatch
import ../../src/hyperx/server
import ./tserver
import ./tutils

proc main() {.async.} =
  echo "Serving forever"
  var server = newServer(
    localHost, localInsecurePort, ssl = false
  )
  await server.serve()

when isMainModule:
  waitFor main()
  doAssert not hasPendingOperations()
  echo "ok"
