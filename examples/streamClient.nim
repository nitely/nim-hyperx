{.define: ssl.}

import std/strutils
import std/asyncdispatch
import ../src/hyperx/client
import ./localServer

func newStringRef(s = ""): ref string =
  new result
  result[] = s

when isMainModule:
  var completed = newSeq[string]()
  proc streamChunks(
    client: ClientContext, path: string, chunks: seq[string]
  ) {.async.} =
    let strm = client.newClientStream()
    withStream strm:
      var contentLen = 0
      for chunk in chunks:
        contentLen += chunk.len
      await strm.sendHeaders(
        hmPost, path,
        contentLen = contentLen
      )
      var i = chunks.len-1
      var data = newStringref()
      for chunk in chunks:
        data[].setLen 0
        data[].add chunk
        await strm.sendBody(data, finish = i == 0)
        dec i
      data[].setLen 0
      await strm.recvHeaders(data)
      doAssert ":status:" in data[]
      data[].setLen 0
      while not strm.recvEnded:
        await strm.recvBody(data)
      for chunk in chunks:
        doAssert chunk in data[]
      echo "Path done: " & path
      echo "Received: " & data[]
    completed.add path

  proc main() {.async.} =
    var server = newServer()
    asyncCheck server.serve()

    var client = newClient(localHost, localPort)
    withClient(client):
      await (
        streamChunks(client, "/foo", @["foo", "bar"]) and
        streamChunks(client, "/bar", @["baz", "qux"])
      )

  waitFor main()
  doAssert completed.len == 2
  doAssert "/foo" in completed
  doAssert "/bar" in completed
  #doAssert not hasPendingOperations()
  echo "ok"
