{.define: ssl.}
{.define: hyperxTest.}

import std/strutils
import std/asyncdispatch
import pkg/hpack
import ../src/hyperx/client
import ../src/hyperx/testutils
import ../src/hyperx/frame
import ../src/hyperx/errors

const
  userAgent = "Nim - HyperX"

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

proc checkHandshake(tc: TestClientContext) {.async.} =
  const preface = "PRI * HTTP/2.0\r\L\r\LSM\r\L\r\L".toBytes
  let data = await tc.sent(preface.len)
  doAssert data == preface
  let frm1 = await tc.sent()
  doAssert frm1.typ == frmtSettings
  doAssert frm1.sid == frmSidMain

proc checkTableSizeAck(tc: TestClientContext) {.async.} =
  let frm1 = await tc.sent()
  doAssert frm1.typ == frmtSettings
  doAssert frm1.sid == frmSidMain
  doAssert frmfAck in frm1.flags

testAsync "simple response":
  const headers = ":status: 200\r\nfoo: foo\r\n"
  const text = "foobar body"
  var resp1: Response
  var tc = newTestClient("foo.bar")
  withConnection tc.client:
    await tc.checkHandshake()
    let get1 = tc.client.get("/")
    let rep1 = tc.reply(headers, text)
    resp1 = await get1
    await rep1
  doAssert resp1.headers == headers
  doAssert resp1.text == text

testAsync "multiple responses":
  const
    headers = ":status: 200\r\nfoo: foo\r\n"
    text = "foo body"
    headers2 = ":status: 200\r\nbar: bar\r\n"
    text2 = "bar body"
  var resp1, resp2: Response
  var tc = newTestClient("foo.bar")
  withConnection tc.client:
    await tc.checkHandshake()
    let get1 = tc.client.get("/")
    let get2 = tc.client.get("/")
    let rep1 = tc.reply(headers, text)
    let rep2 = tc.reply(headers2, text2)
    resp1 = await get1
    resp2 = await get2
    await (rep1 and rep2)
  doAssert resp1.headers == headers
  doAssert resp1.text == text
  doAssert resp2.headers == headers2
  doAssert resp2.text == text2

testAsync "simple request":
  var frm1: Frame
  var tc = newTestClient("foo.bar")
  withConnection tc.client:
    await tc.checkHandshake()
    await (
      tc.client.get("/") and
      tc.reply(":status: 200\r\nfoo: foo\r\n", "bar")
    )
    frm1 = await tc.sent()
  doAssert frm1.sid.int == 1
  doAssert frm1.typ == frmtHeaders
  doAssert frm1.payload.toString() ==
    ":method: GET\r\L" &
    ":scheme: https\r\L" &
    ":path: /\r\L" &
    ":authority: foo.bar\r\L" &
    "user-agent: " & userAgent & "\r\L" &
    "accept: */*\r\L"

testAsync "multiple requests":
  var frm1, frm2, frm3: Frame
  var tc = newTestClient("foo.bar")
  withConnection tc.client:
    await tc.checkHandshake()
    await (
      tc.client.get("/1") and
      tc.reply(":status: 200\r\nfoo: foo\r\n", "bar")
    )
    await (
      tc.client.get("/2") and
      tc.reply(":status: 200\r\nbar: bar\r\n", "bar")
    )
    frm1 = await tc.sent()
    frm2 = await tc.sent()
    frm3 = await tc.sent()
  doAssert frm1.sid.int == 1
  doAssert frm1.typ == frmtHeaders
  doAssert frm1.payload.toString() ==
    ":method: GET\r\L" &
    ":scheme: https\r\L" &
    ":path: /1\r\L" &
    ":authority: foo.bar\r\L" &
    "user-agent: " & userAgent & "\r\L" &
    "accept: */*\r\L"
  # XXX frm2 window update
  doAssert frm3.sid.int == 3
  doAssert frm3.typ == frmtHeaders
  doAssert frm3.payload.toString() ==
    ":method: GET\r\L" &
    ":scheme: https\r\L" &
    ":path: /2\r\L" &
    ":authority: foo.bar\r\L" &
    "user-agent: " & userAgent & "\r\L" &
    "accept: */*\r\L"

testAsync "response with bad header compression":
  proc replyBadHeaders(tc: TestClientContext) {.async.} =
    var frm1 = tc.frame(frmtHeaders, @[frmfEndHeaders])
    frm1.add "abc".toBytes
    await tc.reply(frm1)
  var errorMsg = ""
  var tc = newTestClient("foo.bar")
  withConnection tc.client:
    await tc.checkHandshake()
    try:
      await (
        tc.client.get("/") and
        tc.replyBadHeaders()
      )
    except HyperxConnectionError as err:
      errorMsg = err.msg
  doAssert "COMPRESSION_ERROR" in errorMsg

testAsync "response with headers prio":
  proc replyPrio(tc: TestClientContext; headers, text: string) {.async.} =
    var frm1 = tc.frame(
      frmtHeaders, @[frmfPriority, frmfEndHeaders]
    )
    frm1.add ("12345" & hencode(tc, headers)).toBytes
    await tc.reply(frm1)
    var frm2 = tc.frame(frmtData, @[frmfEndStream])
    frm2.add text.toBytes
    await tc.reply(frm2)
    tc.sid += 2
  const
    headers = ":status: 200\r\nfoo: foo\r\n"
    text = "foo body"
    headers2 = ":status: 200\r\nbar: bar\r\n"
    text2 = "bar body"
  var resp1, resp2: Response
  var tc = newTestClient("foo.bar")
  withConnection tc.client:
    await tc.checkHandshake()
    let get1 = tc.client.get("/")
    let get2 = tc.client.get("/")
    let rep1 = tc.replyPrio(headers, text)
    let rep2 = tc.reply(headers2, text2)
    resp1 = await get1
    resp2 = await get2
    await (rep1 and rep2)
  doAssert resp1.headers == headers
  doAssert resp1.text == text
  doAssert resp2.headers == headers2
  doAssert resp2.text == text2

testAsync "response with bad prio length":
  proc replyPrio(tc: TestClientContext) {.async.} =
    let frm1 = tc.frame(
      frmtHeaders, @[frmfPriority, frmfEndHeaders]
    )
    frm1.add "1".toBytes
    await tc.reply(frm1)
  var errorMsg = ""
  var tc = newTestClient("foo.bar")
  withConnection tc.client:
    await tc.checkHandshake()
    try:
      await (
        tc.client.get("/") and
        tc.replyPrio()
      )
    except HyperxConnectionError as err:
      errorMsg = err.msg
  doAssert "PROTOCOL_ERROR" in errorMsg

testAsync "response with headers padding":
  proc replyPadding(tc: TestClientContext; headers, text: string) {.async.} =
    var frm1 = tc.frame(
      frmtHeaders, @[frmfPadded, frmfEndHeaders]
    )
    frm1.add ("\x01" & hencode(tc, headers) & "12345678").toBytes
    await tc.reply(frm1)
    var frm2 = tc.frame(frmtData, @[frmfEndStream])
    frm2.add text.toBytes
    await tc.reply(frm2)
    tc.sid += 2
  const
    headers = ":status: 200\r\nfoo: foo\r\n"
    text = "foo body"
    headers2 = ":status: 200\r\nbar: bar\r\n"
    text2 = "bar body"
  var resp1, resp2: Response
  var tc = newTestClient("foo.bar")
  withConnection tc.client:
    await tc.checkHandshake()
    let get1 = tc.client.get("/")
    let get2 = tc.client.get("/")
    let rep1 = tc.replyPadding(headers, text)
    let rep2 = tc.reply(headers2, text2)
    resp1 = await get1
    resp2 = await get2
    await (rep1 and rep2)
  doAssert resp1.headers == headers
  doAssert resp1.text == text
  doAssert resp2.headers == headers2
  doAssert resp2.text == text2

testAsync "response with bad over padding length":
  proc replyPadding(tc: TestClientContext) {.async.} =
    var frm1 = tc.frame(
      frmtHeaders, @[frmfPadded, frmfEndHeaders]
    )
    frm1.add ("\xfd" & hencode(tc, ":me: foo\r\L")).toBytes
    await tc.reply(frm1)
  var errorMsg = ""
  var tc = newTestClient("foo.bar")
  withConnection tc.client:
    await tc.checkHandshake()
    try:
      await (
        tc.client.get("/") and
        tc.replyPadding()
      )
    except HyperxConnectionError as err:
      errorMsg = err.msg
  doAssert "PROTOCOL_ERROR" in errorMsg

testAsync "response with bad missing padding length":
  proc replyPadding(tc: TestClientContext) {.async.} =
    let frm1 = tc.frame(
      frmtHeaders, @[frmfPadded, frmfEndHeaders]
    )
    await tc.reply(frm1)
  var errorMsg = ""
  var tc = newTestClient("foo.bar")
  withConnection tc.client:
    await tc.checkHandshake()
    try:
      await (
        tc.client.get("/") and
        tc.replyPadding()
      )
    except HyperxConnectionError as err:
      errorMsg = err.msg
  doAssert "PROTOCOL_ERROR" in errorMsg

testAsync "header table is populated":
  var frm1: Frame
  var tc = newTestClient("foo.bar")
  withConnection tc.client:
    await tc.checkHandshake()
    await (
      tc.client.get("/foo") and
      tc.reply(":status: 200\r\nfoo: foo\r\n", "bar")
    )
    frm1 = await tc.sent()
  doAssert tc.peer.headersDec.len == 4
  doAssert $tc.peer.headersDec ==
    "accept: */*\r\L" &
    "user-agent: " & userAgent & "\r\L" &
    ":authority: foo.bar\r\L" &
    ":path: /foo\r\L"
  doAssert frm1.sid.int == 1
  doAssert frm1.typ == frmtHeaders
  doAssert frm1.payload.toString() ==
    ":method: GET\r\L" &
    ":scheme: https\r\L" &
    ":path: /foo\r\L" &
    ":authority: foo.bar\r\L" &
    "user-agent: " & userAgent & "\r\L" &
    "accept: */*\r\L"

testAsync "header table size setting is applied":
  proc recvTableSizeSetting(tc: TestClientContext, tableSize: uint32) {.async.} =
    var frm1 = frame(frmtSettings, frmSidMain)
    frm1.addSetting(frmsHeaderTableSize, tableSize)
    await tc.reply(frm1)
  var frm1: Frame
  var tc = newTestClient("foo.bar")
  withConnection tc.client:
    await tc.checkHandshake()
    await tc.recvTableSizeSetting(0)
    await tc.checkTableSizeAck()
    await (
      tc.client.get("/foo") and
      tc.reply(":status: 200\r\nfoo: foo\r\n", "bar")
    )
    frm1 = await tc.sent()
    # XXX window size update
    #frm2 = await tc.sent()
    # XXX ack window size update
    #frm3 = await tc.sent()
  doAssert tc.peer.headersDec.len == 0
  doAssert frm1.sid.int == 1
  doAssert frm1.typ == frmtHeaders
  doAssert frm1.payload.toString ==
    ":method: GET\r\L" &
    ":scheme: https\r\L" &
    ":path: /foo\r\L" &
    ":authority: foo.bar\r\L" &
    "user-agent: " & userAgent & "\r\L" &
    "accept: */*\r\L"

testAsync "response stream":
  const headers = ":status: 200\r\nfoo: foo\r\n"
  const text = "foobar body"
  let content = newStringRef()
  var tc = newTestClient("foo.bar")
  withConnection tc.client:
    await tc.checkHandshake()
    let strm = tc.client.newClientStream()
    withStream strm:
      await strm.sendHeaders(hmGet, "/")
      await tc.reply(headers, text)
      await strm.recvHeaders(content)
      while not strm.ended:
        await strm.recvBody(content)
  doAssert content[] == headers & text
