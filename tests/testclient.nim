{.define: ssl.}
{.define: hyperxTest.}

import std/strutils
import std/asyncdispatch
import pkg/hpack
import ../src/hyperx/client
import ../src/hyperx/testutils
import ../src/hyperx/frame
import ../src/hyperx/errors

func toBytes(s: string): seq[byte] =
  result = newSeq[byte]()
  for c in s:
    result.add c.byte

testAsync "simple response":
  const headers = ":method: foobar\r\L"
  const text = "foobar body"
  var tc = newTestClient("foo.bar")
  withConnection tc:
    await (
      tc.get("/") and
      tc.reply(headers, text)
    )
  doAssert tc.resps[0].headers == headers
  doAssert tc.resps[0].text == text

testAsync "multiple responses":
  const
    headers = ":method: foo\r\L"
    text = "foo body"
    headers2 = ":method: bar\r\L"
    text2 = "bar body"
  var tc = newTestClient("foo.bar")
  withConnection tc:
    await (
      tc.get("/") and
      tc.reply(headers, text) and
      tc.get("/") and
      tc.reply(headers2, text2)
    )
  doAssert tc.resps[0].headers == headers
  doAssert tc.resps[0].text == text
  doAssert tc.resps[1].headers == headers2
  doAssert tc.resps[1].text == text2

testAsync "multiple responses unordered":
  const
    headers = ":method: foo\r\L"
    text = "foo body"
    headers2 = ":method: bar\r\L"
    text2 = "bar body"
  var tc = newTestClient("foo.bar")
  withConnection tc:
    await (
      tc.get("/") and
      tc.get("/") and
      tc.reply(headers, text) and
      tc.reply(headers2, text2)
    )
  doAssert tc.resps[0].headers == headers
  doAssert tc.resps[0].text == text
  doAssert tc.resps[1].headers == headers2
  doAssert tc.resps[1].text == text2

testAsync "simple request":
  var tc = newTestClient("foo.bar")
  withConnection tc:
    await (
      tc.get("/") and
      tc.reply("foo: foo\r\L", "bar")
    )
  let reqs = tc.sent()
  doAssert reqs[0].frm.sid == frmsidMain
  doAssert reqs[0].frm.typ == frmtSettings
  #doAssert reqs[0].payload.len == 0
  doAssert reqs[1].frm.sid.int == 1
  doAssert reqs[1].frm.typ == frmtHeaders
  doAssert reqs[1].payload ==
    ":method: GET\r\L" &
    ":scheme: https\r\L" &
    ":path: /\r\L" &
    ":authority: foo.bar\r\L"

testAsync "multiple requests":
  var tc = newTestClient("foo.bar")
  withConnection tc:
    await (
      tc.get("/1") and
      tc.reply("foo: foo\r\L", "bar") and
      tc.get("/2") and
      tc.reply("foo: foo\r\L", "bar")
    )
  let reqs = tc.sent()
  doAssert reqs[0].frm.sid == frmsidMain
  doAssert reqs[0].frm.typ == frmtSettings
  #doAssert reqs[0].payload.len == 0
  doAssert reqs[1].frm.sid.int == 1
  doAssert reqs[1].frm.typ == frmtHeaders
  doAssert reqs[1].payload ==
    ":method: GET\r\L" &
    ":scheme: https\r\L" &
    ":path: /1\r\L" &
    ":authority: foo.bar\r\L"
  doAssert reqs[2].frm.sid.int == 3
  doAssert reqs[2].frm.typ == frmtHeaders
  doAssert reqs[2].payload ==
    ":method: GET\r\L" &
    ":scheme: https\r\L" &
    ":path: /2\r\L" &
    ":authority: foo.bar\r\L"

testAsync "response with bad header compression":
  proc replyBadHeaders(tc: TestClientContext) {.async.} =
    var frm1 = tc.frame(frmtHeaders, @[frmfEndHeaders])
    frm1.add "abc".toBytes
    await tc.reply(frm1)
  var errorMsg = ""
  var tc = newTestClient("foo.bar")
  try:
    withConnection tc:
      await (
        tc.get("/") and
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
    headers = ":method: foo\r\L"
    text = "foo body"
    headers2 = ":method: bar\r\L"
    text2 = "bar body"
  var tc = newTestClient("foo.bar")
  withConnection tc:
    await (
      tc.get("/") and
      tc.replyPrio(headers, text) and
      tc.get("/") and
      tc.reply(headers2, text2)
    )
  doAssert tc.resps[0].headers == headers
  doAssert tc.resps[0].text == text
  doAssert tc.resps[1].headers == headers2
  doAssert tc.resps[1].text == text2

testAsync "response with bad prio length":
  proc replyPrio(tc: TestClientContext) {.async.} =
    let frm1 = tc.frame(
      frmtHeaders, @[frmfPriority, frmfEndHeaders]
    )
    frm1.add "1".toBytes
    await tc.reply(frm1)
  var errorMsg = ""
  var tc = newTestClient("foo.bar")
  try:
    withConnection tc:
      await (
        tc.get("/") and
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
    headers = ":method: foo\r\L"
    text = "foo body"
    headers2 = ":method: bar\r\L"
    text2 = "bar body"
  var tc = newTestClient("foo.bar")
  withConnection tc:
    await (
      tc.get("/") and
      tc.replyPadding(headers, text) and
      tc.get("/") and
      tc.reply(headers2, text2)
    )
  doAssert tc.resps[0].headers == headers
  doAssert tc.resps[0].text == text
  doAssert tc.resps[1].headers == headers2
  doAssert tc.resps[1].text == text2

testAsync "response with bad over padding length":
  proc replyPadding(tc: TestClientContext) {.async.} =
    var frm1 = tc.frame(
      frmtHeaders, @[frmfPadded, frmfEndHeaders]
    )
    frm1.add ("\xfd" & hencode(tc, ":me: foo\r\L")).toBytes
    await tc.reply(frm1)
  var errorMsg = ""
  var tc = newTestClient("foo.bar")
  try:
    withConnection tc:
      await (
        tc.get("/") and
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
  try:
    withConnection tc:
      await (
        tc.get("/") and
        tc.replyPadding()
      )
  except HyperxConnectionError as err:
    errorMsg = err.msg
  doAssert "PROTOCOL_ERROR" in errorMsg

testAsync "header table is populated":
  var tc = newTestClient("foo.bar")
  withConnection tc:
    await (
      tc.get("/foo") and
      tc.reply("foo: foo\r\L", "bar")
    )
  let reqs = tc.sent()
  doAssert tc.headersDec.len == 2
  doAssert $tc.headersDec ==
    ":authority: foo.bar\r\L" &
    ":path: /foo\r\L"
  doAssert reqs[1].frm.sid.int == 1
  doAssert reqs[1].frm.typ == frmtHeaders
  doAssert reqs[1].payload ==
    ":method: GET\r\L" &
    ":scheme: https\r\L" &
    ":path: /foo\r\L" &
    ":authority: foo.bar\r\L"

testAsync "header table size setting is applied":
  proc recvTableSizeSetting(tc: TestClientContext, tableSize: uint32) {.async.} =
    var frm1 = frame(frmtSettings, frmsidMain)
    frm1.addSetting(frmsHeaderTableSize, tableSize)
    await tc.reply(frm1)
  var tc = newTestClient("foo.bar")
  withConnection tc:
    # XXX wait for sent ACK, and do one single request
    await tc.recvTableSizeSetting(0)
    await (
      tc.get("/foo") and
      tc.reply("foo: foo\r\L", "bar")
    )
    await (
      tc.get("/bar") and
      tc.reply("foo2: foo2\r\L", "bar2")
    )
  let reqs = tc.sent()
  doAssert tc.headersDec.len == 0
  doAssert reqs[1].frm.sid.int == 1
  doAssert reqs[1].frm.typ == frmtHeaders
  doAssert reqs[1].payload ==
    ":method: GET\r\L" &
    ":scheme: https\r\L" &
    ":path: /foo\r\L" &
    ":authority: foo.bar\r\L"
  # XXX reqs[2] window size update
  doAssert reqs[3].frm.sid.int == 3
  doAssert reqs[3].frm.typ == frmtHeaders
  doAssert reqs[3].payload ==
    ":method: GET\r\L" &
    ":scheme: https\r\L" &
    ":path: /bar\r\L" &
    ":authority: foo.bar\r\L"
