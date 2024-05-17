{.define: ssl.}

import std/strutils
import std/asyncdispatch
import ../src/hyperx/client
import ../src/hyperx/server
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
    let serveFut = server.serve(propagateErr = false)

    var client = newClient(localHost, localPort)
    withClient(client):
      await (
        streamChunks(client, "/foo", @["foo", "bar"]) and
        streamChunks(client, "/bar", @["baz", "qux"])
      )
    # we don't keep track of streams and clients
    # so this may not terminate everything
    try:
      server.close()
      await serveFut
    except HyperxConnError as err:
      #debugEcho err.getStackTrace()
      #debugEcho err.msg
      debugEcho "server conn err or closed"
    # let strm/clients handlers terminate
    await sleepAsync(1000)

  waitFor main()
  doAssert completed.len == 2
  doAssert "/foo" in completed
  doAssert "/bar" in completed
  #doAssert not hasPendingOperations()
  #setGlobalDispatcher(nil)
  #GC_fullCollect()
  echo "ok"
