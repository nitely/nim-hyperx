# HyperX

> [!WARNING]
> Do not use. This lib is in pre-alpha state.

Pure Nim Http2 client/server implementation.

## Compatibility

> Latest Nim only

## Client

While the client is not stable, it should be functional as
most of the spec is implemented.

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
