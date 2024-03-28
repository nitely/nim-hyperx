when not defined(hyperxTest):
  {.error: "tests need -d:hyperxTest".}

when not defined(ssl):
  {.error: "this lib needs -d:ssl".}

import std/strutils
import std/asyncdispatch
import pkg/hpack
import ./frame
import ./clientserver
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

type
  PeerContext = ref object
    headersEnc*, headersDec*: DynHeaders
  TestClientContext* = ref object
    client*: ClientContext
    peer*: PeerContext
    sid*: int

func newPeerContext(): PeerContext =
  PeerContext(
    headersEnc: initDynHeaders(4096),
    headersDec: initDynHeaders(4096)
  )

func newTestClient*(hostname: string): TestClientContext =
  TestClientContext(
    client: newClient(hostname, Port 443),
    peer: newPeerContext(),
    sid: 1
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
    discard hencode(parts[0], parts[1], tc.peer.headersEnc, resp)
  result = resp.toString

proc reply*(
  tc: TestClientContext,
  headers: string,
  text: string
) {.async.} =
  var frm1 = frame(
    frmtHeaders, tc.sid.FrmSid, @[frmfEndHeaders]
  )
  frm1.add hencode(tc, headers).toBytes
  await tc.client.putRecvTestData frm1.s
  var frm2 = frame(
    frmtData, tc.sid.FrmSid, @[frmfEndStream]
  )
  frm2.add text.toBytes
  await tc.client.putRecvTestData frm2.s
  tc.sid += 2

proc reply*(
  tc: TestClientContext,
  frm: Frame
) {.async.} =
  await tc.client.putRecvTestData frm.s

proc sent*(tc: TestClientContext, size: int): Future[seq[byte]] {.async.} =
  result = await tc.client.sentTestData(size)

proc sent*(tc: TestClientContext): Future[Frame] {.async.} =
  result = newEmptyFrame()
  result.s = await tc.client.sentTestData(frmHeaderSize)
  doAssert result.len == frmHeaderSize
  var payload = newSeq[byte]()
  if result.payloadLen.int > 0:
    payload = await tc.client.sentTestData(result.payloadLen.int)
    doAssert payload.len == result.payloadLen.int
  if result.typ == frmtHeaders:
    var ds = initDecodedStr()
    hdecodeAll(payload, tc.peer.headersDec, ds)
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
