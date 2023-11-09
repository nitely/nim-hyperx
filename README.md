# HyperX

> Warning: Do not use. This lib is in pre-alpha state.
  It's likely broken. Only a few parts of the spec are
  implemented. I'm focusing on coding the client ATM.
  If you want to join the effort, you are welcome.
  Just read the spec and fix whatever is broken.
  Do not create issues unless you are gonna work on them :)

Pure Nim Http2 client/server implementation.

## Compatibility

> Latest Nim only

## Client

This snippet actually works at the time of writing

```nim
{.define: ssl.}

import std/asyncdispatch
import pkg/hyperx/client

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
```

## Server

Unimplemented

## Debugging

This will print received frames, and some other
debugging messages

```
nim c -r -d:hyperxDebug client.nim
```

## LICENSE

MIT
