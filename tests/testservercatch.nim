## Test raise error within stream without -d:hyperxLetItCrash

{.define: hyperxSanityCheck.}

import std/asyncdispatch
import ../src/hyperx/client
import ../src/hyperx/server
from ../src/hyperx/errors import hyxCancel

const localPort = Port 8774
const localHost = "127.0.0.1"

type MyError = object of CatchableError

proc test {.async.} =
  var checked = 0
  let server = newServer(
    localHost, localPort, ssl = false
  )
  let serveFut = server.serve(proc (strm: ClientStream) {.async.} =
    try:
      raise (ref MyError)()
    finally:
      await strm.cancel(hyxCancel)
      inc checked
  )
  let client = newClient(localHost, localPort, ssl = false)
  with client:
    try:
      discard await client.get("/")
      doAssert false
    except HyperxStrmError as err:
      doAssert err.code.int == hyxCancel.int
  server.close()
  try:
    await serveFut
  except HyperxConnError:
    discard
  doAssert checked == 1

discard getGlobalDispatcher()
waitFor test()
doAssert not hasPendingOperations()
echo "ok"
