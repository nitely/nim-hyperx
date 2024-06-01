{.define: ssl.}

import std/strutils
import std/asyncdispatch
import ../src/hyperx/client
from ./localServer import localHost, localPort

func newStringRef(s = ""): ref string =
  new result
  result[] = s

when isMainModule:
  var completed = newSeq[string]()

  proc send(
    strm: ClientStream, path: string, chunks: seq[string]
  ) {.async.} =
    var contentLen = 0
    for chunk in chunks:
      contentLen += chunk.len
    await strm.sendHeaders(
      hmPost, path,
      contentLen = contentLen
    )
    var data = newStringRef()
    var i = 0
    for chunk in chunks:
      data[].setLen 0
      data[].add chunk
      await strm.sendBody(data, finish = i == chunks.high)
      inc i

  proc recv(
    strm: ClientStream, data: ref string
  ) {.async.} =
    await strm.recvHeaders(data)
    doAssert ":status:" in data[]
    data[].setLen 0
    while not strm.recvEnded:
      await strm.recvBody(data)

  proc streamChunks(
    client: ClientContext, path: string, chunks: seq[string]
  ) {.async.} =
    let strm = client.newClientStream()
    withStream strm:
      # send and recv concurrently
      var data = newStringRef()
      let recvFut = strm.recv(data)
      let sendFut = strm.send(path, chunks)
      await recvFut
      await sendFut
      var expectedData = ""
      for chunk in chunks:
        expectedData.add chunk
      doAssert expectedData == data[]
      echo "Path done: " & path
      echo "Received: " & data[]
      completed.add path

  proc main() {.async.} =
    var client = newClient(localHost, localPort)
    withClient(client):
      # send chunks concurrently
      let chunkFut1 = streamChunks(client, "/foo", @["foo", "bar"])
      let chunkFut2 = streamChunks(client, "/bar", @["baz", "qux"])
      await chunkFut1
      await chunkFut2

  waitFor main()
  doAssert completed.len == 2
  doAssert "/foo" in completed
  doAssert "/bar" in completed
  doAssert not hasPendingOperations()
  #setGlobalDispatcher(nil)
  #GC_fullCollect()
  echo "ok"
