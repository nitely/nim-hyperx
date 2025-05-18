{.define: ssl.}
{.define: hyperxSanityCheck.}
{.define: hyperxLetItCrash.}

from std/os import getEnv
import std/asyncdispatch
import ../../src/hyperx/server
import ./tserver
import ./tutils

const certFile = getEnv "HYPERX_TEST_CERTFILE"
const keyFile = getEnv "HYPERX_TEST_KEYFILE"

# XXX graceful shutdown

proc run =
  run(
    localHost,
    localMultiThreadPort,
    processStream,
    certFile,
    keyFile,
    threads = 4
  )

when isMainModule:
  run()
