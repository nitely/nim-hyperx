{.define: ssl.}

import std/strutils
import std/asyncdispatch
import ../src/hyperx/client

when isMainModule:
  var responses = newSeq[Response]()
  proc main() {.async.} =
    var client = newClient("www.google.com")
    withClient(client):
      let queries = [
        "john+wick",
        "winston",
        "ms+perkins"
      ]
      var tasks = newSeq[Future[Response]]()
      for q in queries:
        tasks.add client.get("/search?q=" & q)
      responses = await all(tasks)
  waitFor main()
  doAssert responses.len == 3
  for r in responses:
    doAssert ":status: 200" in r.headers
    doAssert "doctype" in r.text
  doAssert not hasPendingOperations()
  echo "ok"
