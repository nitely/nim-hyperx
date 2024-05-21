## Make a single client, send all the raw-data
## requests serially. Compare all server recv
## headers with client sent headers and the other way.

{.define: ssl.}

import std/asyncdispatch
import ../../src/hyperx/client
import ./tutils.nim

proc main() {.async.} =
  var checked = 0
  var client = newClient(localHost, localPort)
  withClient(client):
    for story in stories("raw-data"):
      for headers in cases(story):
        doAssert headers.isRequest
        # there is only one case with content
        if headers.contentLen != 0:
          continue
        let rawHeaders = headers.rawHeaders()
        let strm = client.newClientStream()
        withStream strm:
          let headersRef = new(seq[Header])
          headersRef[] = headers
          await strm.sendHeaders(headersRef, finish = true)
          var data = newStringref()
          await strm.recvHeaders(data)
          doAssert data[] ==
            ":status: 200\r\n" &
            "content-type: text/plain\r\n" &
            "content-length: " & $rawHeaders.len & "\r\n"
          data[].setLen 0
          while not strm.recvEnded:
            await strm.recvBody(data)
          doAssert data[] == rawHeaders
          inc checked
  doAssert checked == 348
  echo "checked ", $checked

(proc =
  waitFor main()
  doAssert not hasPendingOperations()
  echo "ok"
)()
