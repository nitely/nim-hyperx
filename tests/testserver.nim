{.define: ssl.}
{.define: hyperxTest.}

import std/strutils
import std/asyncdispatch
import pkg/hpack
import ../src/hyperx/server
import ../src/hyperx/testutils
import ../src/hyperx/frame
import ../src/hyperx/errors
from ../src/hyperx/clientserver import
  stgWindowSize, stgInitialWindowSize

func toBytes(s: string): seq[byte] =
  result = newSeq[byte]()
  for c in s:
    result.add c.byte

func toString(s: openArray[byte]): string =
  result = ""
  for c in s:
    result.add c.char

func newStringRef(s = ""): ref string =
  new result
  result[] = s

const
  userAgent = "Nim - HyperX"
  preface = "PRI * HTTP/2.0\r\L\r\LSM\r\L\r\L".toBytes

proc checkHandshake(tc: TestClientContext) {.async.} =
  let frm1 = await tc.sent()
  doAssert frm1.typ == frmtSettings
  doAssert frm1.sid == frmSidMain
  if stgWindowSize > stgInitialWindowSize:
    let frm2 = await tc.sent()
    doAssert frm2.typ == frmtWindowUpdate
    doAssert frm2.sid == frmSidMain

testAsync "simple request":
  var checked = false
  const headers =
    ":method: GET\r\n" &
    ":path: /\r\n" &
    ":scheme: https\r\n" &
    "foo: foo\r\n"
  const text = "0123456789"
  var server = newServer(
    "foo.bar", Port 443, "./cert", "./key"
  )
  withServer server:
    let client1 = await server.recvClient()
    let tc1 = newTestClient(client1)
    await tc1.recv(preface)
    withClient tc1.client:
      await tc1.checkHandshake()
      await tc1.recv(headers)
      let strm = await client1.recvStream()
      withStream strm:
        var data = newStringRef()
        await strm.recvHeaders(data)
        doAssert data[] == headers
        doAssert strm.recvEnded
        await strm.sendHeaders(
          status = 200,
          contentType = "text/plain",
          contentLen = text.len
        )
        await strm.sendBody(newStringRef(text), finish = true)
      let frm1 = await tc1.sent()
      doAssert frm1.sid.int == 1
      doAssert frm1.typ == frmtHeaders
      doAssert frm1.payload.toString ==
        ":status: 200\r\L" &
        "content-type: text/plain\r\L" &
        "content-length: 10\r\L"
      doAssert frmfEndStream notin frm1.flags
      let frm2 = await tc1.sent()
      doAssert frm2.sid.int == 1
      doAssert frm2.typ == frmtData
      doAssert frm2.payload.toString == text
      doAssert frmfEndStream in frm2.flags
      checked = true
  doAssert checked
