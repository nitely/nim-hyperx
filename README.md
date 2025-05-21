# HyperX

Pure Nim Http2 client/server implementation. Tested with [h2spec](https://github.com/summerwind/h2spec), and [h2load](https://nghttp2.org/documentation/h2load-howto.html).

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

proc main {.async.} =
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

```nim
{.define: ssl.}

import std/asyncdispatch
import pkg/hyperx/server

const
  localHost = "127.0.0.1"
  localPort = Port 8888
  certFile = "/usr/src/app/example.com+5.pem"
  keyFile = "/usr/src/app/example.com+5-key.pem"

proc processStream(strm: ClientStream) {.async.} =
  ## Consume the stream and send hello world!.
  let data = new string
  await strm.recvHeaders(data)
  while not strm.recvEnded:
    data[].setLen 0
    await strm.recvBody(data)
  await strm.sendHeaders(
    @[(":status", "200")], finish = false
  )
  data[] = "Hello world!"
  await strm.sendBody(data, finish = true)

proc main {.async.} =
  echo "Serving forever"
  let server = newServer(
    localHost, localPort, certFile, keyFile
  )
  await server.serve(processStream)

waitFor main()
echo "ok"
```

Beware HTTP/2 requires TLS, so if you want to test the server locally you'll need a local cert. I used [mkcert](https://github.com/FiloSottile/mkcert) to generate mine.

You may disable SSL by passing `ssl = false` to `newServer/newClient` for local testing.

## Usage

Read the [examples](https://github.com/nitely/nim-hyperx/blob/master/examples/).

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

Backpressure is based on the http2 spec flow-control. The amount of data a connection can process at a time is bounded by the flow-control window size. Not calling recv in time will buffer up to window size of data. Setting a window smaller than 64KB is not well supported.

### Using http/2 in place of WebSockets

Http/2 allows full-duplex data communication over a single stream. If you plan to only ever use this client and server, you won't need websockets.

However, web-browsers do not support full-duplex streaming. So http/2 cannot be used in place of websockets there. If you only need unidirectional communication from server to client, consider using SSE (server-sent events) instead.

### Benchmarks

A multi-thread server (same as localHost but using the `run` proc), compiled with orc, 16 threads, ssl disabled is able to process +2M requests/s on a Ryzen 9.

```text
$ h2load -n3000000 -c32 -m100 -ph2c -t4 http://127.0.0.1:8783
finished in 1.43s, 2103304.50 req/s, 62.18MB/s
```

### Memory leaks

Use `--mm:refc`. It only leaks under orc; one reason is [this](https://github.com/nim-lang/Nim/issues/23615), I did not investigate further.

### ORC

Nim's stdlib async creates cycles, and the ORC cycle collector does not run often enough. Related [nim issue](https://github.com/nim-lang/Nim/issues/21631). This has been fixed in Nim +2.2.2, however orc has other memory issues as mentioned above. You may want to use `--mm:refc` instead of orc.

### SSL

Do not use SSL until [this](https://github.com/nim-lang/Nim/pull/24896) gets merged and released. Also, Nim 2.2.2 and older may raise a SIGSEGV because of [this](https://github.com/nim-lang/Nim/pull/24795) (ex: if there is a protocol error, or under some other condition hyperx may close the connection while in use), this one has been fixed in Nim +2.2.4.

### Related libs

- [nim-grpc](https://github.com/nitely/nim-grpc)

## LICENSE

MIT
