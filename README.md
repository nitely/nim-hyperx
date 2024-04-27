# HyperX

Pure Nim Http2 client/server implementation.

Beware this library is in heavy development,
and the API is not stable.

> [!NOTE]
> This library supports HTTP/2 only. Not HTTP/1, nor HTTP/3.

## Install

```
nimble install hyperx
```

## Compatibility

> Nim +2.0

## Client

```nim

# this define needs to be in the main nim file
# or pass it as a compiler parameter `-d:ssl`
# or define it in the nim.cfg file
{.define: ssl.}

import std/asyncdispatch
import pkg/hyperx/client

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
    let responses = await all(tasks)
    for r in responses:
      doAssert ":status: 200" in r.headers
      doAssert "doctype" in r.text
waitFor main()
echo "ok"
```

## Server

See [examples/localServer.nim](https://github.com/nitely/nim-hyperx/blob/master/examples/localServer.nim)

Beware HTTP/2 requires TLS, so if you want to test the server locally you'll
need a local cert. I used [mkcert](https://github.com/FiloSottile/mkcert)
to generate mine. Idk if there is an easier way to try this.

## Debugging

This will print received frames, and some other
debugging messages

```
nim c -r -d:hyperxDebug client.nim
```

## LICENSE

MIT
