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
    var checked = false
    proc test() {.async.} =
      body
      checked = true
    discard getGlobalDispatcher()
    waitFor test()
    # check there are no dangling async futures
    doAssert not hasPendingOperations()
    doAssert checked
    when false:  # for finding mem leaks
      setGlobalDispatcher(nil)
      GC_fullCollect()
    when false:  # when defined(orc):
      # requires -d:nimAllocStats
      let stats = getAllocStats()
      doAssert stats.allocCount == stats.deallocCount
  )()

proc sleepCycle*: Future[void] =
  let fut = newFuture[void]()
  proc wakeup = fut.complete()
  callSoon wakeup
  return fut

func toString(bytes: openArray[byte]): string =
  result = ""
  for b in bytes:
    result.add b.char

proc frame*(
  typ: FrmTyp,
  sid: FrmSid,
  flags: seq[FrmFlag] = @[]
): Frame =
  result = initFrame()
  result.setTyp typ
  result.setSid sid
  for f in flags:
    result.flags.incl f

type
  PeerContext = ref object
    headersEnc*, headersDec*: Hpack
  TestClientContext* = ref object
    client*: ClientContext
    peer*: PeerContext
    sid*: int

func newPeerContext(): PeerContext =
  PeerContext(
    headersEnc: initHpack(4096),
    headersDec: initHpack(4096)
  )

func newTestClient*(client: ClientContext): TestClientContext =
  TestClientContext(
    client: client,
    peer: newPeerContext(),
    sid: 1
  )

func newTestClient*(hostname: string): TestClientContext =
  newTestClient(newClient(hostname, Port 443))

proc frame*(
  tc: TestClientContext,
  typ: FrmTyp,
  flags: seq[FrmFlag] = @[]
): Frame =
  result = frame(typ, tc.sid.FrmSid, flags)

proc hencodeBytes(tc: TestClientContext, hs: string): seq[byte] =
  result = newSeq[byte]()
  for h in hs.splitLines:
    if h.len == 0:
      continue
    let parts = h.split(": ", 1)
    discard hencode(parts[0], parts[1], tc.peer.headersEnc, result)

proc hencode*(tc: TestClientContext, hs: string): string =
  tc.hencodeBytes(hs).toString

proc reply*(
  tc: TestClientContext,
  headers: string,
  text: string
) {.async.} =
  var frm1 = frame(
    frmtHeaders, tc.sid.FrmSid, @[frmfEndHeaders]
  )
  frm1.add tc.hencodeBytes(headers)
  await tc.client.putRecvTestData frm1.s
  var frm2 = frame(
    frmtData, tc.sid.FrmSid, @[frmfEndStream]
  )
  frm2.add text.toOpenArrayByte(0, text.high)
  await tc.client.putRecvTestData frm2.s
  tc.sid += 2

proc reply*(
  tc: TestClientContext,
  frm: Frame
) {.async.} =
  await tc.client.putRecvTestData frm.s

proc recv*(tc: TestClientContext, headers: string) {.async.} =
  var frm1 = frame(
    frmtHeaders, tc.sid.FrmSid, @[frmfEndHeaders, frmfEndStream]
  )
  frm1.add tc.hencodeBytes(headers)
  await tc.client.putRecvTestData frm1.s
  tc.sid += 2

proc recv*(
  tc: TestClientContext,
  headers: string,
  sid: int,
  finish: bool
) {.async.} =
  var frm1 = frame(frmtHeaders, sid.FrmSid, @[frmfEndHeaders])
  if finish:
    frm1.flags.incl frmfEndStream
  frm1.add tc.hencodeBytes(headers)
  await tc.client.putRecvTestData frm1.s

proc recv*(tc: TestClientContext, s: seq[byte]) {.async.} =
  await tc.client.putRecvTestData s

proc sent*(tc: TestClientContext, size: int): Future[seq[byte]] {.async.} =
  result = await tc.client.sentTestData(size)

proc sent*(tc: TestClientContext): Future[Frame] {.async.} =
  result = initEmptyFrame()
  result.s = await tc.client.sentTestData(frmHeaderSize)
  doAssert result.len > 0, "Client closed"
  doAssert result.len == frmHeaderSize
  var payload = newSeq[byte]()
  if result.payloadLen.int > 0:
    payload = await tc.client.sentTestData(result.payloadLen.int)
    doAssert payload.len == result.payloadLen.int
  if result.typ == frmtHeaders:
    var ss = newSeq[byte]()
    var bb = newSeq[HpackBound]()
    hdecodeAll(payload, tc.peer.headersDec, ss, bb)
    result.add ss
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
