{.define: ssl.}

import std/asyncdispatch
import ../../src/hyperx/client
import ./tserver.nim
import ./tutils.nim
import ../../src/hyperx/signal

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

proc spawnStream(
  client: ClientContext,
  headers: Headers,
  checked: ref int
) {.async.} =
  let strm = client.newClientStream()
  withStream strm:
    await strm.sendHeaders(headers.s, finish = true)
    var data = newStringref()
    await strm.recvHeaders(data)
    doAssert data[] ==
      ":status: 200\r\n" &
      "content-type: text/plain\r\n" &
      "content-length: " & $headers.raw[].len & "\r\n"
    data[].setLen 0
    while not strm.recvEnded:
      await strm.recvBody(data)
    doAssert data[] == headers.raw[]
    inc checked[]

proc spawnStream(
  client: ClientContext,
  headers: Headers,
  checked: ref int,
  sig: SignalAsync,
  inFlight: ref int
) {.async.} =
  try:
    await spawnStream(client, headers, checked)
  finally:
    inFlight[] = inFlight[] - 1
    sig.trigger()

const strmsPerClient = 10000
const clientsCount = 10

proc spawnClient(
  headersCtx: HeadersCtx,
  checked: ref int
) {.async.} =
  var client = newClient(localHost, localPort)
  withClient(client):
    var strms = newSeq[Future[void]]()
    var stmsCount = 0
    var inFlight = new(int)
    inFlight[] = 0
    var sig = newSignal()
    while stmsCount < strmsPerClient:
      for headers in headersCtx.s:
        inFlight[] = inFlight[] + 1
        strms.add spawnStream(client, headers, checked, sig, inFlight)
        inc stmsCount
        if stmsCount >= strmsPerClient:
          break
        #if inFlight[] == 100:
        #  await sig.waitFor()
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