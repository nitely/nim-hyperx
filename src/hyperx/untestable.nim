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
      echo "G"
      let r = await client.get("/")
      doAssert ":status: 200" in r.headers
      doAssert "doctype" in r.text
      await sleepAsync 2000
  waitFor main()

  proc mainReqBin() {.async.} =
    var client = newClient("reqbin.com")
    withConnection(client):
      block:
        echo "GET"
        let r = await client.get(
          "/echo/get/json",
          accept = "application/json"
        )
        doAssert ":status: 200" in r.headers
        doAssert """{"success":"true"}""" in r.text
      block:
        echo "POST"
        let r = await client.post(
          "/echo/post/json",
          """{"foo": "bar"}""".toBytes,
          contentType = "application/json"
        )
        doAssert ":status: 200" in r.headers
        doAssert """{"success":"true"}""" in r.text
      block:
        echo "HEAD"
        let r = await client.head("/echo")
        doAssert ":status: 200" in r.headers
        doAssert r.text.len == 0
      await sleepAsync 2000
  waitFor mainReqBin()

  echo "ok"
