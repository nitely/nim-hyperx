# HyperX

Pure Nim Http2 client/server implementation. Tested with [h2spec](https://github.com/summerwind/h2spec), and [h2load](https://nghttp2.org/documentation/h2load-howto.html).

Beware this library is in heavy development, and the API is not stable.

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
  let client = newClient("www.google.com")
  with client:
    let queries = ["john+wick", "winston", "ms+perkins"]
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

Beware HTTP/2 requires TLS, so if you want to test the server locally you'll need a local cert. I used [mkcert](https://github.com/FiloSottile/mkcert) to generate mine. Idk if there is an easier way to try this.

## Debugging

This will print received frames, and some other debugging messages

```
nim c -r -d:hyperxDebug client.nim
```

## Notes

### Why?

Http/2 supports high concurrency over a single connection through stream multiplexing.

Http/1 can only compete by enabling [pipelining](https://en.wikipedia.org/wiki/HTTP_pipelining), which is what most http/1 benchmarks do. But web-browsers do not enable it, and you may not want to enable it for good reasons. It produces [head of line blocking](https://en.wikipedia.org/wiki/Head-of-line_blocking) at the application level.

### Serving http/1 and http/3 traffic

You may use a reverse proxy such as [Caddy](https://github.com/caddyserver/caddy) or a cloud offering such as AWS ALB for this. Look for a service that can receive http/1, 2, 3 traffic and forward it as http/2 to hyperx.

### Data streaming

Both server and client support data streaming. The [data stream example](https://github.com/nitely/nim-hyperx/blob/master/examples/dataStream.nim) shows how to transfer 1GB of total data with minimal memory usage. Increasing the data size won't increase the memory usage.

### Backpressure

Backpressure is based on the http2 spec flow-control. The amount of data a connection can process at a time is bounded by the flow-control window size. The initial window size is set to 256KB. Not calling recv in time will buffer up to window size of data.

The window size can be set using the `hyperxWindowSize` define. For example `-d:hyperxWindowSize:65536` will set the size to the http/2 spec default of 64KB. Setting a window smaller than 64KB is not well supported.

There is built-in backpressure based on bounded queues for the rest of non-data frames.

### Using http/2 in place of WebSockets

Http/2 allows full-duplex data communication over a single stream. If you plan to only ever use this client and server, you won't need websockets.

On web-browsers, only [chrome](https://caniuse.com/mdn-api_request_request_request_body_readablestream) has support for streaming, and it's only [half-duplex](https://github.com/whatwg/fetch/issues/1254). So, you need two streams, one for sending, and one for receiving.

### Benchmarks

The CI runs h2load on it, but it only starts a single server instance. Proper benchmarking would start a server per CPU, and run a few combinations of load. To save you the trip, the CI results show around 30K requests/s.

### Related libs

- [nim-grpc](https://github.com/nitely/nim-grpc)

## LICENSE

MIT
