# HyperX

Pure Nim Http2 client/server implementation. Tested with
[h2spec](https://github.com/summerwind/h2spec), and
[h2load](https://nghttp2.org/documentation/h2load-howto.html).

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

## Requirements

- OpenSSL

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

## FAQ

### What if I need to serve http/1 and http/3 traffic?

You may use a reverse proxy such a [Caddy](https://github.com/caddyserver/caddy) or a cloud offering such as AWS ALB for this. There are many ways to enumerate them all, but basically look for a service that can receive http/1, 2, 3 traffic and forward it as http/2.

### Is data streaming supported?

Yes. Both server and client support data streaming. See the examples.

### Can I use http/2 in place of WebSockets?

If you don't need to serve web-browsers, then yes. Http/2 allows full-duplex data communication over a single stream. Web-browsers only support half-duplex streaming [for whatever reason](https://github.com/whatwg/fetch/issues/1254).

If you need to support web-browsers it gets tricky for some use cases, as you need to do two fetches, one to stream the request, one to stream the response, and something like an ID in the URL so the server can associate both streams.

### Are there benchmarks?

The CI runs h2load on it, but it only starts a single server instance. Proper bench-marking would start a server per CPU, and run a few combinations of load. To save you the trip, the CI results show around 30K requests/s.

## LICENSE

MIT
