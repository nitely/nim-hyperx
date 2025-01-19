{.define: ssl.}
{.define: hyperxSanityCheck.}

from std/os import getEnv
import std/asyncdispatch
import ../../src/hyperx/server
import ./tserver
import ./tutils

const certFile = getEnv "HYPERX_TEST_CERTFILE"
const keyFile = getEnv "HYPERX_TEST_KEYFILE"

proc main() {.async.} =
  echo "Serving forever"
  var server = newServer(
    localHost, localMultiThreadPort, certFile, keyFile
  )
  await server.serve()

# XXX graceful shutdown

proc worker {.thread.} =
  waitFor main()

proc run =
  var threads = newSeq[Thread[void]](4)
  for i in 0 .. threads.len-1:
    createThread(threads[i], worker)
  for i in 0 .. threads.len-1:
    joinThread(threads[i])

when isMainModule:
  run()
