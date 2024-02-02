{.define: ssl.}
{.define: hyperxTest.}

import std/strutils
import std/asyncdispatch
import pkg/hpack
import ../src/hyperx/client
import ../src/hyperx/testutils
import ../src/hyperx/frame
import ../src/hyperx/errors

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
  doAssert reqs[0].payload.len == 0
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
  doAssert reqs[0].payload.len == 0
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
    let headerPl = "abc"
    let frm1 = tc.frame(
      frmtHeaders, headerPl.len, @[frmfEndHeaders]
    )
    await tc.reply(frm1, headerPl)
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
    let headerPl = "12345" & hencode(tc, headers)
    let frm1 = tc.frame(
      frmtHeaders, headerPl.len, @[frmfPriority, frmfEndHeaders]
    )
    await tc.reply(frm1, headerPl)
    let frm2 = tc.frame(frmtData, text.len, @[frmfEndStream])
    await tc.reply(frm2, text)
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
    let prio = "1"
    let frm1 = tc.frame(
      frmtHeaders, prio.len, @[frmfPriority, frmfEndHeaders]
    )
    await tc.reply(frm1, prio)
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
    let headerPl = "\x01" & hencode(tc, headers) & "12345678"
    let frm1 = tc.frame(
      frmtHeaders, headerPl.len, @[frmfPadded, frmfEndHeaders]
    )
    await tc.reply(frm1, headerPl)
    let frm2 = tc.frame(frmtData, text.len, @[frmfEndStream])
    await tc.reply(frm2, text)
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
    let headerPl = "\xfd" & hencode(tc, ":me: foo\r\L")
    let frm1 = tc.frame(
      frmtHeaders, headerPl.len, @[frmfPadded, frmfEndHeaders]
    )
    await tc.reply(frm1, headerPl)
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
    let headerPl = ""
    let frm1 = tc.frame(
      frmtHeaders, headerPl.len, @[frmfPadded, frmfEndHeaders]
    )
    await tc.reply(frm1, headerPl)
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

testAsync "reset header table":
  proc recvTableSizeSetting(tc: TestClientContext, tableSize: int) {.async.} =
    var payload = "\x00"
    payload.add frmsHeaderTableSize.char
    payload.add "\x00\x00\x00"
    payload.add tableSize.char
    let frm1 = frame(
      frmtSettings,
      frmsidMain,
      payload.len.FrmPayloadLen
    )
    await tc.reply(frm1, payload)
  var tc = newTestClient("foo.bar")
  withConnection tc:
    # XXX need to wait for main consumer to drain
    #     doing two get makes sure that occurs but
    #     it's hacky
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
  doAssert reqs[2].frm.sid.int == 3
  doAssert reqs[2].frm.typ == frmtHeaders
  doAssert reqs[2].payload ==
    ":method: GET\r\L" &
    ":scheme: https\r\L" &
    ":path: /bar\r\L" &
    ":authority: foo.bar\r\L"
