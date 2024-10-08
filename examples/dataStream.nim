## This sends 1GB to the local server
## run: nim c -r -d:release examples/localServer.nim
## to start the server and then run this one

{.define: ssl.}

import std/strutils
import std/asyncdispatch
import ../src/hyperx/client
from ./localServer import localHost, localPort

const dataSizeMb = 1000
# do not change:
const dataSize = dataSizeMb * 1024 * 1024
const frmSize = 16 * 1024
doAssert dataSize mod frmSize == 0
const chunks = dataSize div frmSize

when isMainModule:
  var dataSentSize = 0
  var dataRecvSize = 0

  proc send(
    strm: ClientStream, path: string
  ) {.async.} =
    await strm.sendHeaders(
      hmPost, path,
      contentLen = dataSize
    )
    var data = new string
    for _ in 0 .. frmSize-1:
      data[].add 'a'
    for i in 0 .. chunks-1:
      await strm.sendBody(data, finish = i == chunks-1)
      dataSentSize += data[].len

  proc recv(
    strm: ClientStream
  ) {.async.} =
    var data = new string
    await strm.recvHeaders(data)
    doAssert ":status:" in data[]
    while not strm.recvEnded:
      data[].setLen 0
      await strm.recvBody(data)
      dataRecvSize += data[].len

  proc streamChunks(
    client: ClientContext, path: string
  ) {.async.} =
    let strm = client.newClientStream()
    with strm:
      let recvFut = strm.recv()
      let sendFut = strm.send(path)
      await recvFut
      await sendFut

  proc main() {.async.} =
    var client = newClient(localHost, localPort)
    with client:
      await streamChunks(client, "/foo")

  waitFor main()
  doAssert not hasPendingOperations()
  doAssert dataSentSize == dataSize
  doAssert dataRecvSize == dataSize
  echo "ok"
