## This sends 1GB to the local server
## run: nim c -r -d:release examples/localServer.nim
## to start the server and then run this one

{.define: ssl.}

import std/strutils
import std/asyncdispatch
import ../src/hyperx/client
import ./localServer

const dataSizeMb = 1000
# do not change:
const dataSize = dataSizeMb * 1024 * 1024
const frmSize = 16 * 1024

func newStringRef(s = ""): ref string =
  new result
  result[] = s

when isMainModule:
  var dataSentSize = 0
  var dataRecvSize = 0
  proc streamChunks(
    client: ClientContext, path: string
  ) {.async.} =
    let strm = client.newClientStream()
    withStream strm:
      await strm.sendHeaders(
        hmPost, path,
        contentLen = dataSize
      )
      var data = newStringref()
      for _ in 0 .. frmSize-1:
        data[].add 'a'
      let chunks = dataSize div frmSize
      for i in 0 .. chunks-1:
        await strm.sendBody(data, finish = i == chunks-1)
        dataSentSize += data[].len
      data[].setLen 0
      await strm.recvHeaders(data)
      doAssert ":status:" in data[]
      while not strm.recvEnded:
        data[].setLen 0
        await strm.recvBody(data)
        dataRecvSize += data[].len

  proc main() {.async.} =
    var client = newClient(localHost, localPort)
    withClient(client):
      await streamChunks(client, "/foo")

  waitFor main()
  doAssert dataSentSize == dataSize
  #doAssert dataRecvSize == dataSize
  doAssert dataRecvSize > 0
  echo "ok"
