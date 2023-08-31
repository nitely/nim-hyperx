## HTTP/2 server
## WIP

type
  Header = object
    s: string
    name, value: Slice[int]

proc toHeader(n, v: string): Header {.compiletime.} =
  Header(
    s: n & ": " & v & "\r\L",
    name: 0 .. n.len-1,
    value: n.len .. n.len+v.len-1)

type
  Response* = object
    s: string
    hline: Slice[int]
    headers: seq[Slice[int]]
    content: Slice[int]

proc add(resp: var Response, h: Header) =
  resp.s.add(h.s)
  resp.headers.add(h.name)
  resp.headers.add(h.value)

proc add*(resp: var Response, hl: string) =
  assert resp.headers.len == 0
  resp.headers.add(resp.s.len .. resp.s.len+hl.len)
  resp.s.add(hl)
  resp.s.add("\r\L")

proc add*(resp: var Response, n, v: string) =
  resp.headers.add(resp.s.len .. resp.s.len+n.len)
  resp.s.add(n)
  resp.s.add(": ")
  resp.headers.add(resp.s.len .. resp.s.len+v.len)
  resp.s.add(v)
  resp.s.add("\r\L")

proc terminate(resp: var Response)
  resp.s.add("\r\L")

proc write(resp: Response) =
  resp.terminate()
  write(resp.s)

proc isUpgrade(req: Request) =
  # s3.2 HTTP/1.1 request MUST include exactly one HTTP2-Settings
  req.has("Connection", "Upgrade") and
  req.count("HTTP2-Settings") == 1

type
  ReqCode = enum
    rcExit
    rcUpgrade

proc processRequests2(
    req: var Request,
    resp: var Response) =
  ## Process HTTP/2 Request
  discard

proc processRequests11(
    req: var Request,
    resp: var Response): ReqCode =
  ## Process HTTP/1 Request
  result = rcExit
  if req.headers.get("Upgrade") == "h2":
    # TLS is negotiated in another way (s3.3)
    return
  if req.isUpgrade:
    resp.add("HTTP/1.1 101 Switching Protocols")
    resp.add(("Connection", "Upgrade").toHeader)
    resp.add(("Upgrade", "h2c").toHeader)
    resp.write()
    # response to original req must be http2
    return rcUpgrade

  # dispatch url, etc

proc processRequests(req: var Request) =
  var rc = rcExit
  if req.isHttp1:
    rc = req.processRequests11()
    if rc == rcExit:
      return
  assert req.isHttp2 or rc == rcUpgrade
  req.processRequests2()
