## Shared utilities

import ./errors

template definedSsl*(def: untyped): untyped =
  when defined(ssl):
    def

func stackTrace2(err: ref Exception): string {.raises: [].} =
  doAssert err != nil
  result = ""
  result.add err.getStackTrace
  result.add "Error: "
  result.add err.msg
  result.add " ["
  result.add err.name
  result.add ']'

func fulltrace(err: ref Exception): string {.raises: [].} =
  doAssert err != nil
  result = ""
  var e = err
  while e != nil:
    result.add e.stackTrace2()
    if e.parent != nil:
      result.add "\nreraised from:\n"
    e = e.parent

func trace*(err: ref HyperxError): string {.raises: [].} =
  fulltrace err

template `?=`*(exp1, exp2: untyped): untyped =
  if exp1 == nil:
    exp1 = exp2

func debugErr2*(err: ref Exception) {.raises: [].} =
  # This func should not be needed, but just in case
  when defined(hyperxDebugErr2):
    debugEcho err.stackTrace2()
  else:
    discard

func debugErr*(err: ref Exception) {.raises: [].} =
  when defined(hyperxDebug) or defined(hyperxDebugErr):
    debugEcho fulltrace(err)
  else:
    discard

template debugInfo*(s: untyped): untyped =
  when defined(hyperxDebug):
    # hide "s" expresion side effcets
    {.cast(noSideEffect).}:
      debugEcho s
  else:
    discard

template check*(cond, errObj: untyped): untyped =
  {.line: instantiationInfo(fullPaths = true).}:
    if not cond:
      raise errObj

template raisesAssertion*(exp: untyped): untyped =
  ## Checks the expression passed raises an assertion
  {.line: instantiationInfo(fullPaths = true).}:
    block:
      var asserted = false
      try:
        exp
      except AssertionDefect:
        asserted = true
      doAssert asserted

template uncatch*(body: untyped): untyped =
  ## workaround for API errors in Nim's stdlib
  try:
    body
  except Defect as err:
    raise err  # raise original error
  except Exception as err:
    debugErr err
    raise newException(Defect, err.msg, err)

template catch*(body: untyped): untyped =
  try:
    body
  except Defect as err:
    raise err  # raise original error
  except Exception as err:
    debugErr2 err
    raise newConnError(err.msg, err)

func add*(s: var seq[byte], ss: openArray[char]) {.raises: [].} =
  if ss.len == 0: return
  let L = s.len
  when nimvm:
    s.setLen(L+ss.len)
    for i in 0 .. ss.len-1:
      s[L+i] = ss[i].byte
  else:
    s.setLen(L+ss.len)
    moveMem(addr s[L], unsafeAddr ss[0], ss.len)

func add*(s: var string, ss: openArray[byte]) {.raises: [].} =
  if ss.len == 0: return
  let L = s.len
  when nimvm:
    s.setLen(L+ss.len)
    for i in 0 .. ss.len-1:
      s[L+i] = ss[i].char
  else:
    s.setLen(L+ss.len)
    prepareMutation(s)
    moveMem(addr s[L], unsafeAddr ss[0], ss.len)

func parseBigInt(s: openArray[byte]): int64 {.raises: [ValueError].} =
  if s.len == 0:
    raise newException(ValueError, "not a number")
  const validChars = {'0' .. '9'}
  var i = 0
  result = 0
  while i < s.len:
    if s[i].char notin validChars:
      raise newException(ValueError, "not a number")
    let c = ord(s[i].char) - ord('0')
    if result > (int64.high - c) div 10:
      raise newException(ValueError, "number out of range")
    result = result * 10 + c
    inc i

# XXX remove once frm is string
func find(s: openArray[byte], c: byte, i: int): int {.raises: [].} =
  result = -1
  var i = i
  while i < s.len:
    if s[i] == c:
      return i
    inc i

func `==`(a: openArray[byte], b: string): bool {.raises: [].} =
  if a.len != b.len:
    return false
  var i = 0
  while i < a.len:
    if a[i] != b[i].byte:
      return false
    inc i
  return true

func contains(s: openArray[string], item: openArray[byte]): bool {.raises: [].} =
  result = false
  for x in s:
    if item == x:
      return true

# XXX move headers stuff to its own module
#     or back to clientserver, it's not used
#     anywhere else
iterator headersIt(s: openArray[byte]): (Slice[int], Slice[int]) {.inline, raises: [].} =
  # this assumes field validity was done
  let L = s.len
  var na = 0
  var nb = 0
  var va = 0
  var vb = 0
  while na < L:
    nb = na
    nb += int(s[na].char == ':')  # pseudo-header
    nb = find(s, ':'.byte, nb)
    doAssert nb != -1
    assert s[nb].char == ':'
    assert s[nb+1].char == ' '
    va = nb+2  # skip :\s
    vb = find(s, '\r'.byte, va)
    doAssert vb != -1
    assert s[vb].char == '\r'
    assert s[vb+1].char == '\n'
    yield (na .. nb-1, va .. vb-1)
    doAssert vb+2 > na
    na = vb+2  # skip /r/n

func contentLen*(s: openArray[byte]): int64 {.raises: [ValueError].} =
  result = -1
  var val = 0 .. -1
  for (nn, vv) in headersIt(s):
    if toOpenArray(s, nn.a, nn.b) == "content-length":
      if val.b != -1:
        raise newException(ValueError, "more than one content-length")
      val = vv
  if val.b != -1:
    return parseBigInt toOpenArray(s, val.a, val.b)

const connSpecificHeaders = [
  "connection",
  "proxy-connection",
  "keep-alive",
  "transfer-encoding",
  "upgrade"
]

func serverHeadersValidation*(s: openArray[byte]) {.raises: [HyperxStrmError].} =
  var hasPath = false
  var hasMethod = false
  var hasScheme = false
  var regularFieldCount = 0
  for (nn, vv) in headersIt(s):
    if s[nn.a].char != ':':
      inc regularFieldCount
      check toOpenArray(s, nn.a, nn.b) notin connSpecificHeaders,
        newStrmError(hyxProtocolError)
      if toOpenArray(s, nn.a, nn.b) == "te":
        check toOpenArray(s, vv.a, vv.b) == "trailers",
          newStrmError(hyxProtocolError)
    else:
      check regularFieldCount == 0, newStrmError(hyxProtocolError)
      if toOpenArray(s, nn.a, nn.b) == ":path":
        check vv.len > 0, newStrmError(hyxProtocolError)
        check not hasPath, newStrmError(hyxProtocolError)
        hasPath = true
      elif toOpenArray(s, nn.a, nn.b) == ":method":
        check not hasMethod, newStrmError(hyxProtocolError)
        hasMethod = true
      elif toOpenArray(s, nn.a, nn.b) == ":scheme":
        check not hasScheme, newStrmError(hyxProtocolError)
        hasScheme = true
      else:
        check toOpenArray(s, nn.a, nn.b) == ":authority",
          newStrmError(hyxProtocolError)
  check hasMethod, newStrmError(hyxProtocolError)
  check hasScheme, newStrmError(hyxProtocolError)
  check hasPath, newStrmError(hyxProtocolError)

func clientHeadersValidation*(s: openArray[byte]) {.raises: [HyperxStrmError].} =
  var hasStatus = false
  var regularFieldCount = 0
  for (nn, vv) in headersIt(s):
    if s[nn.a].char != ':':
      inc regularFieldCount
      check toOpenArray(s, nn.a, nn.b) notin connSpecificHeaders,
        newStrmError(hyxProtocolError)
      check toOpenArray(s, nn.a, nn.b) != "te",
        newStrmError(hyxProtocolError)
    else:
      check regularFieldCount == 0, newStrmError(hyxProtocolError)
      check toOpenArray(s, nn.a, nn.b) == ":status",
        newStrmError(hyxProtocolError)
      check not hasStatus, newStrmError(hyxProtocolError)
      hasStatus = true
  check hasStatus, newStrmError(hyxProtocolError)

func validateTrailers*(s: openArray[byte]) {.raises: [HyperxStrmError].} =
  for (nn, _) in headersIt(s):
    check s[nn.a].char != ':', newStrmError(hyxProtocolError)

when isMainModule:
  func toBytes(s: string): seq[byte] =
    result = newSeq[byte]()
    for c in s:
      result.add c.byte
  block:
    raisesAssertion(doAssert false)
    var raised = false
    try:
      raisesAssertion(doAssert true)
    except AssertionDefect:
      raised = true
    doAssert raised
  block:
    raisesAssertion(catch(doAssert false))
  block:
    try:
      catch:
        raise newException(ValueError, "foo")
      doAssert false
    except HyperxConnError as err:
      doAssert err.msg == "foo"
      doAssert err.parent.msg == "foo"
  block content_len:
    doAssert contentLen(newSeq[byte]()) == -1
    doAssert contentLen(":foo: abc\r\n".toBytes) == -1
    doAssert contentLen("content-length: 100\r\n".toBytes) == 100
    doAssert contentLen("content-length: 00012345678\r\n".toBytes) == 12345678
    doAssert contentLen(":foo: abc\r\ncontent-length: 100\r\n".toBytes) == 100
    doAssert contentLen(
      ":foo: abc\r\ncontent-length-x: 123\r\ncontent-length: 100\r\n".toBytes
    ) == 100
    doAssert contentLen(
      ":foo: abc\r\nontent-length: 123\r\ncontent-length: 100\r\n".toBytes
    ) == 100
    try:
      discard contentLen(":foo: abc\r\ncontent-length: \r\n".toBytes)
      doAssert false
    except ValueError:
      discard
    try:
      discard contentLen(":foo: abc\r\ncontent-length: -123\r\n".toBytes)
      doAssert false
    except ValueError:
      discard
    try:
      discard contentLen(":foo: abc\r\ncontent-length: abc\r\n".toBytes)
      doAssert false
    except ValueError:
      discard
    try:
      discard contentLen(":foo: abc\r\ncontent-length: 1 2 3\r\n".toBytes)
      doAssert false
    except ValueError:
      discard
    try:
      discard contentLen(
        ":foo: abc\r\ncontent-length: 123\r\ncontent-length: 123\r\n".toBytes
      )
      doAssert false
    except ValueError:
      discard
  block headers_it:
    func headersStr(s: string): seq[string] {.raises: [].} =
      for (nn, vv) in headersIt(s.toBytes):
        result.add s[nn]
        result.add s[vv]
    block:
      doAssert headersStr("").len == 0
      doAssert headersStr(":foo: bar\r\n") == @[":foo", "bar"]
      doAssert headersStr(":foo: bar\r\n:foo: bar\r\n") ==
        @[":foo", "bar", ":foo", "bar"]
      doAssert headersStr(":foo: bar\r\n:baz: qux\r\n") ==
        @[":foo", "bar", ":baz", "qux"]
      doAssert headersStr(":foo: bar\r\nbaz: qux\r\n") ==
        @[":foo", "bar", "baz", "qux"]
      doAssert headersStr(":foo: bar 123\r\nbaz: qux abc\r\n") ==
        @[":foo", "bar 123", "baz", "qux abc"]
      doAssert headersStr(":foo: bar :\r\nbaz: qux : abc\r\n") ==
        @[":foo", "bar :", "baz", "qux : abc"]
      doAssert headersStr("foo: bar\r\n") == @["foo", "bar"]
      doAssert headersStr("foo: bar\r\nfoo: bar\r\n") ==
        @["foo", "bar", "foo", "bar"]
      doAssert headersStr("foo: bar\r\nbaz: qux\r\n") ==
        @["foo", "bar", "baz", "qux"]
      doAssert headersStr("foo: \r\nbaz: qux\r\n") ==
        @["foo", "", "baz", "qux"]
      doAssert headersStr("foo: \r\nbaz: \r\n") ==
        @["foo", "", "baz", ""]
      doAssert headersStr("foo: bar\r\nbaz: \r\n") ==
        @["foo", "bar", "baz", ""]
      doAssert headersStr(":: \r\nx: \r\n") ==
        @[":", "", "x", ""]

  echo "ok"