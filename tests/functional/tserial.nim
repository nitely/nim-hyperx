## Make a single client, send all the raw-data
## requests serially. Compare all server recv
## headers with client sent headers and the other way.
## Compare server hpack state with client hpack state (enc/dec).

{.define: ssl.}

import ./tserver.nim
import ./tutils.nim
import ../../src/hyperx/client

proc main() {.async.} =
  var checked = 0
  var client = newClient(localHost, localPort)
  withClient(client):
    for story in stories:
      for headers in cases(story):
        var data = newStringref()
        let strm = client.newClientStream()
        withStream strm:
          await strm.sendHeaders(headers)
          while not strm.recvEnded:
            await strm.recvBody(data)
        doAssert data[] == headers.rawHeaders
        inc checked
  echo checked

(proc =
  waitFor main()
  doAssert not hasPendingOperations()
  echo "ok"
)()
