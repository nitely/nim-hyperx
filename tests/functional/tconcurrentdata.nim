{.define: ssl.}

import std/asyncdispatch
import ../../src/hyperx/client
import ../../src/hyperx/signal
import ./tserver.nim
import ./tutils.nim

type
  Headers = object
    s: ref seq[Header]
    raw: ref string
  Data = object
    s: ref string
  Req = object
    headers: Headers
    data: Data
  ReqsCtx = ref object
    s: seq[Req]

func newHeaders(s: seq[Header]): Headers =
  result = Headers(
    s: new(seq[Header]),
    raw: new(string)
  )
  result.s[] = s
  result.raw[] = s.rawHeaders

func newData(s: string): Data =
  Data(s: newStringRef(s))

func newReq(headers: Headers, data: Data): Req =
  Req(
    headers: headers,
    data: data
  )

func newReqsCtx(): ReqsCtx =
  ReqsCtx(
    s: newSeq[Req]()
  )

proc spawnStream(
  client: ClientContext,
  req: Req,
  checked: ref int
) {.async.} =
  let strm = client.newClientStream()
  withStream strm:
    await strm.sendHeaders(req.headers.s, finish = false)
    await strm.sendBody(req.data.s, finish = true)
    var data = newStringref()
    await strm.recvHeaders(data)
    let exptLen = req.headers.raw[].len + req.data.s[].len
    doAssert data[] ==
      ":status: 200\r\n" &
      "content-type: text/plain\r\n" &
      "content-length: " & $exptLen & "\r\n"
    data[].setLen 0
    while not strm.recvEnded:
      await strm.recvBody(data)
    doAssert data[] == req.headers.raw[] & req.data.s[]
    inc checked[]

proc spawnStream(
  client: ClientContext,
  req: Req,
  checked: ref int,
  sig: SignalAsync,
  inFlight: ref int
) {.async.} =
  try:
    await spawnStream(client, req, checked)
  finally:
    inFlight[] = inFlight[] - 1
    sig.trigger()

const strmsPerClient = 10000
const clientsCount = 10
const strmsInFlight = 100

proc spawnClient(
  reqsCtx: ReqsCtx,
  checked: ref int
) {.async.} =
  var client = newClient(localHost, localPort)
  withClient(client):
    var stmsCount = 0
    var inFlight = new(int)
    inFlight[] = 0
    var sig = newSignal()
    while stmsCount < strmsPerClient:
      for req in reqsCtx.s:
        inFlight[] = inFlight[] + 1
        asyncCheck spawnStream(client, req, checked, sig, inFlight)
        inc stmsCount
        if stmsCount >= strmsPerClient:
          break
        if inFlight[] == strmsInFlight:
          await sig.waitFor()
    while inFlight[] > 0:
      await sig.waitFor()

proc main() {.async.} =
  var data = newSeq[string]()
  for c in 'a' .. 'z':
    data.add ""
    for _ in 0 .. 1024:
      data[^1].add c
  let reqsCtx = newReqsCtx()
  for i in 0 .. data.len-1:
    reqsCtx.s.add newReq(
      newHeaders(@[
        (":method", "POST"),
        (":scheme", "https"),
        (":path", "/file/" & $i),
        (":authority", "foo.bar"),
        ("user-agent", "HyperX/0.1"),
        ("content-type", "text/plain"),
        ("content-length", $data[i].len)
      ]),
      newData(data[i])
    )
  let checked = new(int)
  checked[] = 0
  var clients = newSeq[Future[void]]()
  for _ in 0 .. clientsCount-1:
    clients.add spawnClient(reqsCtx, checked)
  for clientFut in clients:
    await clientFut
  doAssert checked[] == clientsCount * strmsPerClient
  echo "checked ", $checked[]

(proc =
  waitFor main()
  doAssert not hasPendingOperations()
  echo "ok"
)()
