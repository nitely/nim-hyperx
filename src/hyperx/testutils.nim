when not defined(hyperxTest):
  {.error: "tests need -d:hyperxTest".}

{.define: ssl.}

import std/strutils
import std/asyncdispatch
import pkg/hpack/encoder
import ./frame
import ./client

template test*(name: string, body: untyped): untyped =
  block:
    echo "test " & name
    body

func toString(bytes: openArray[byte]): string =
  let L = bytes.len
  if L > 0:
    result = newString(L)
    copyMem(result.cstring, bytes[0].unsafeAddr, L)
  
proc frame(
  typ: FrmTyp,
  sid: FrmSid,
  pl: FrmPayloadLen,
  flags: seq[FrmFlag] = @[]
): string =
  var frm = newFrame()
  frm.setTyp typ
  frm.setSid sid
  for f in flags:
    frm.flags.incl f
  frm.setPayloadLen pl
  result = frm.rawStr()

type
  TestClientContext* = ref object
    c: ClientContext
    sid: int
    resps*: seq[Response]
    dh: DynHeaders

func newTestClient*(hostname: string): TestClientContext =
  result = TestClientContext(
    c: newClient(hostname, Port 443),
    sid: 1,
    resps: newSeq[Response](),
    dh: initDynHeaders(1024, 16)
  )

proc hencode(tc: TestClientContext, hs: string): string =
  var resp = newSeq[byte]()
  for h in hs.splitLines:
    if h.len == 0:
      continue
    let parts = h.split(": ", 1)
    discard hencode(parts[0], parts[1], tc.dh, resp)
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
  let encHeaders = hencode(tc, headers)
  await tc.c.putTestData frame(
    frmtHeaders, tc.sid.FrmSid, encHeaders.len.FrmPayloadLen, @[frmfEndHeaders]
  )
  await tc.c.putTestData encHeaders
  await tc.c.putTestData frame(
    frmtData, tc.sid.FrmSid, text.len.FrmPayloadLen, @[frmfEndStream]
  )
  await tc.c.putTestData text
  tc.sid += 2
