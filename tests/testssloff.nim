# just check this compiles without -d:ssl

import std/asyncdispatch
import ../src/hyperx/server
import ../src/hyperx/client

const localHost = "127.0.0.1"
const localPort = Port 8783
let srv = newServer(localHost, localPort, ssl = false)
let clt = newClient(localHost, localPort, ssl = false)
doAssert false  # do not run this file
