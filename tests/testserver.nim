{.define: ssl.}
{.define: hyperxTest.}

import std/strutils
import std/asyncdispatch
import pkg/hpack
import ../src/hyperx/server
import ../src/hyperx/testutils
import ../src/hyperx/frame
import ../src/hyperx/errors

func toBytes(s: string): seq[byte] =
  result = newSeq[byte]()
  for c in s:
    result.add c.byte

func toString(s: openArray[byte]): string =
  result = ""
  for c in s:
    result.add c.char

func newStringRef(): ref string =
  new result
  result[] = ""

const
  userAgent = "Nim - HyperX"
  preface = "PRI * HTTP/2.0\r\L\r\LSM\r\L\r\L".toBytes

proc checkHandshake(tc: TestClientContext) {.async.} =
  let frm1 = await tc.sent()
  doAssert frm1.typ == frmtSettings
  doAssert frm1.sid == frmSidMain

testAsync "simple request":
  var server = newServer(
    "foo.bar", Port 443, "./cert", "./key"
  )
  withServer server:
    let client1 = await server.recvClient()
    let tc1 = newTestClient(client1)
    let prefacefut = tc1.client.recv(preface)
    withClient tc1.client:
      await tc1.checkHandshake()
      await prefacefut
    #  let strm = await client.recvStream()
