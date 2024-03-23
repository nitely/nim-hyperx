when not defined(hyperxTest):
  {.error: "tests need -d:hyperxTest".}

{.define: ssl.}

import std/strutils
import std/asyncdispatch
import pkg/hpack
import ./frame
import ./client

template testAsync*(name: string, body: untyped): untyped =
  (proc () = 
    echo "test " & name
    proc test() {.async.} =
      body
    waitFor test()
  )()

func toString(bytes: openArray[byte]): string =
  result = ""
  for b in bytes:
    result.add b.char

func toBytes(s: string): seq[byte] =
  result = newSeq[byte]()
  for c in s:
    result.add c.byte

proc frame*(
  typ: FrmTyp,
  sid: FrmSid,
  flags: seq[FrmFlag] = @[]
): Frame =
  result = newFrame()
  result.setTyp typ
  result.setSid sid
  for f in flags:
    result.flags.incl f

# XXX
# client: ClientContext
# peer: PeerContext
# remove resps
type
  TestClientContext* = ref object
    c*: ClientContext
    sid: int
    resps*: seq[Response]
    headersEnc*, headersDec*: DynHeaders

func newTestClient*(hostname: string): TestClientContext =
  result = TestClientContext(
    c: newClient(hostname, Port 443),
    sid: 1,
    resps: newSeq[Response](),
    headersEnc: initDynHeaders(4096),
    headersDec: initDynHeaders(4096)
  )

proc frame*(
  tc: TestClientContext,
  typ: FrmTyp,
  flags: seq[FrmFlag] = @[]
): Frame =
  result = frame(typ, tc.sid.FrmSid, flags)

proc hencode*(tc: TestClientContext, hs: string): string =
  var resp = newSeq[byte]()
  for h in hs.splitLines:
    if h.len == 0:
      continue
    let parts = h.split(": ", 1)
    discard hencode(parts[0], parts[1], tc.headersEnc, resp)
  result = resp.toString

template withConnection*(tc: TestClientContext, body: untyped): untyped =
  withConnection tc.c:
    body

proc get*(tc: TestClientContext, path: string) {.async.} =
  tc.resps.add await tc.c.get(path)

proc reply*(
  tc: TestClientContext,
  headers: string,
  text: string
) {.async.} =
  var frm1 = frame(
    frmtHeaders, tc.sid.FrmSid, @[frmfEndHeaders]
  )
  frm1.add hencode(tc, headers).toBytes
  await tc.c.putRecvTestData frm1.s
  var frm2 = frame(
    frmtData, tc.sid.FrmSid, @[frmfEndStream]
  )
  frm2.add text.toBytes
  await tc.c.putRecvTestData frm2.s
  tc.sid += 2

proc reply*(
  tc: TestClientContext,
  frm: Frame
) {.async.} =
  await tc.c.putRecvTestData frm.s

proc sent*(tc: TestClientContext, size: int): Future[seq[byte]] {.async.} =
  result = await tc.c.sentTestData(size)

proc sent*(tc: TestClientContext): Future[Frame] {.async.} =
  result = newEmptyFrame()
  result.s = await tc.c.sentTestData(frmHeaderSize)
  doAssert result.len == frmHeaderSize
  var payload = newSeq[byte]()
  if result.payloadLen.int > 0:
    payload = await tc.c.sentTestData(result.payloadLen.int)
    doAssert payload.len == result.payloadLen.int
  if result.typ == frmtHeaders:
    var ds = initDecodedStr()
    hdecodeAll(payload, tc.headersDec, ds)
    result.add toBytes($ds)
  else:
    result.add payload

when isMainModule:
  block:
    testAsync "foobar":
      doAssert true
  block:
    var asserted = false
    try:
      testAsync "foobar":
        doAssert false
    except AssertionDefect:
      asserted = true
    doAssert asserted

  echo "ok"
