{.define: ssl.}

import std/asyncdispatch
import ./client

when isMainModule:
  proc main() {.async.} =
    var client = newClient("www.google.com")
    withConnection(client):
      let r = await client.get("/")
      echo r.headers
      echo r.text[0 .. 10]
      await sleepAsync 2000
  waitFor main()

  echo "ok"
