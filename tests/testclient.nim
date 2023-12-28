{.define: ssl.}

import std/asyncdispatch
import ../src/hyperx/client
import ../src/hyperx/testutils

testAsync "sanity check req/resp":
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

testAsync "sanity check multiple req/resp":
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

testAsync "sanity check multiple req/resp order":
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
