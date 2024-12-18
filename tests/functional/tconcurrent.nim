## READ: this goes over the default max number of
## concurrent streams; define -d:hyperxMaxConcurrentStrms=1000000
## on the server

{.define: ssl.}
{.define: hyperxSanityCheck.}

import std/asyncdispatch
import ../../src/hyperx/client
import ./tutils.nim

type
  Headers = object
    s: ref seq[Header]
    raw: ref string
  HeadersCtx = ref object
    s: seq[Headers]

func newHeaders(s: seq[Header]): Headers =
  result = Headers(
    s: new(seq[Header]),
    raw: new(string)
  )
  result.s[] = s
  result.raw[] = s.rawHeaders

func newHeadersCtx(): HeadersCtx =
  HeadersCtx(
    s: newSeq[Headers]()
  )

proc recv(strm: ClientStream, data: ref string) {.async.} =
  await strm.recvHeaders(data)
  doAssert data[] == ":status: 200\r\n"
  data[].setLen 0
  while not strm.recvEnded:
    await strm.recvBody(data)

proc spawnStream(
  client: ClientContext,
  headers: Headers,
  checked: ref int
) {.async.} =
  let strm = client.newClientStream()
  with strm:
    let data = newStringref()
    let recvFut = strm.recv(data)
    let sendFut = strm.sendHeaders(headers.s[], finish = true)
    await recvFut
    await sendFut
    doAssert data[] == headers.raw[]
    inc checked[]

const strmsPerClient = 11000
const clientsCount = 11

proc spawnClient(
  headersCtx: HeadersCtx,
  checked: ref int
) {.async.} =
  var client = newClient(localHost, localPort)
  with client:
    var strms = newSeq[Future[void]]()
    var stmsCount = 0
    while stmsCount < strmsPerClient:
      for headers in headersCtx.s:
        strms.add spawnStream(client, headers, checked)
        inc stmsCount
        if stmsCount >= strmsPerClient:
          break
    for strmFut in strms:
      await strmFut

proc main() {.async.} =
  let headersCtx = newHeadersCtx()
  for story in stories("raw-data"):
    for headers in cases(story):
      doAssert headers.isRequest
      if headers.contentLen != 0:
        continue
      headersCtx.s.add newHeaders(headers)
  let checked = new(int)
  checked[] = 0
  var clients = newSeq[Future[void]]()
  for _ in 0 .. clientsCount-1:
    clients.add spawnClient(headersCtx, checked)
  for clientFut in clients:
    await clientFut
  doAssert checked[] == clientsCount * strmsPerClient
  echo "checked ", $checked[]

(proc =
  waitFor main()
  doAssert not hasPendingOperations()
  echo "ok"
)()
