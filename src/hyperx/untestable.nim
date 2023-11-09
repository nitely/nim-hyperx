{.define: ssl.}

import std/asyncdispatch
import ./client

proc httpGet(client: ClientContext, query: string) {.async.} =
  let r = await client.get("/search?q=" & query)
  echo r.headers
  echo r.text[0..100]

proc main() {.async.} =
  var client = newClient("www.google.com")
  withConnection(client):
    let queries = [
      "john+wick",
      "winston",
      "ms+perkins"
    ]
    var tasks = newSeq[Future[void]]()
    for q in queries:
      tasks.add client.httpGet(q)
    await all(tasks)
waitFor main()
echo "ok"
