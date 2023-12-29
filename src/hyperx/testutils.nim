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

type TestRequest = object
  frm: Frame
  payload: string

proc sent*(tc: TestClientContext): seq[TestRequest] =
  result = newSeq[TestRequest]()
  let data = tc.c.testDataSent()
  if data.len == 0:
    return
  var dh = initDynHeaders(1024, 16)
  #doAssert tc.prefaceSent()
  const prefaceLen = "PRI * HTTP/2.0\r\L\r\LSM\r\L\r\L".len
  var i = prefaceLen
  while i < data.len:
    var frame = newFrame()
    frame.setRawBytes data[i .. i+frmHeaderSize-1].toString
    frame.setRawBytes data[i .. i+frame.len-1].toString
    i += frame.len
    let payload = data[i .. i+frame.payloadLen.int-1]
    i += payload.len
    if frame.typ == frmtHeaders:
      var ds = initDecodedStr()
      hdecodeAll(payload, dh, ds)
      result.add TestRequest(frm: frame, payload: $ds)
    else:
      result.add TestRequest(frm: frame, payload: payload.toString)

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
