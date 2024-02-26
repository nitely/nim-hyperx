{.define: ssl.}

import std/strutils
import std/asyncdispatch
import ./client

func toBytes(s: string): seq[byte] =
  result = newSeq[byte]()
  for c in s:
    result.add c.byte

when isMainModule:
  proc main() {.async.} =
    var client = newClient("www.google.com")
    withConnection(client):
      let r = await client.get("/")
      doAssert ":status: 200" in r.headers
      doAssert "doctype" in r.text
      await sleepAsync 2000
  echo "GET"
  waitFor main()

  proc mainPost() {.async.} =
    var client = newClient("reqbin.com")
    withConnection(client):
      let r = await client.post(
        "/echo/post/form",
        "foo=bar&baz=qux".toBytes
      )
      doAssert ":status: 200" in r.headers
      doAssert "Success" in r.text
      await sleepAsync 2000
  echo "POST"
  waitFor mainPost()

  echo "ok"
