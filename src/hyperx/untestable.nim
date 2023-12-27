{.define: ssl.}

import std/asyncdispatch
import ./client

when isMainModule:
  proc main() {.async.} =
    var client = newClient("google.com")
    withConnection(client):
      let r = await client.get("/")
      echo r.headers
      var dataStr = ""
      dataStr.add r.data.s
      echo dataStr
      await sleepAsync 2000
  waitFor main()

  echo "ok"
