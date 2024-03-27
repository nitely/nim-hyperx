# HyperX

Pure Nim Http2 client/server implementation.

> [!WARNING]
> This library is in alpha state and as such there won't be a
> deprecation period for breaking changes. You are adviced to
> pin the version/commit if you use it.

## Compatibility

> Latest Nim only

## Client

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
