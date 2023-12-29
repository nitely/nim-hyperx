{.define: ssl.}

import std/asyncdispatch
import ../src/hyperx/client
import ../src/hyperx/testutils
import ../src/hyperx/frame

testAsync "simple response":
  const headers = ":method: foobar\r\L"
  const text = "foobar body"
  var tc = newTestClient("example.com")
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
  var tc = newTestClient("example.com")
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
  var tc = newTestClient("example.com")
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
  var tc = newTestClient("example.com")
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
    ":authority: example.com\r\L"

testAsync "multiple requests":
  var tc = newTestClient("example.com")
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
    ":authority: example.com\r\L"
  doAssert reqs[2].frm.sid.int == 3
  doAssert reqs[2].frm.typ == frmtHeaders
  doAssert reqs[2].payload ==
    ":method: GET\r\L" &
    ":scheme: https\r\L" &
    ":path: /2\r\L" &
    ":authority: example.com\r\L"
