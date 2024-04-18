
template raisesAssertion*(exp: untyped): untyped =
  ## Checks the expression passed raises an assertion
  block:
    var asserted = false
    try:
      exp
    except AssertionDefect:
      asserted = true
    doAssert asserted

template untrackExceptions*(body: untyped): untyped =
  ## workaround for API errors in Nim's stdlib
  try:
    body
  except Defect as err:
    raise err  # raise original error
  except Exception as err:
    raise newException(Defect, err.msg)

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

# XXX remove
func toBytes(s: string): seq[byte] {.compileTime.} =
  result = newSeq[byte]()
  for c in s:
    result.add c.byte

func contentLen*(s: openArray[byte]): int {.raises: [ValueError].} =
  const cBytes = "content-length:".toBytes
  result = -1
  let L = s.len
  var start = -1
  var i = 0
  while i < L:
    if toOpenArray(s, i, min(L-1, i+cBytes.len-1)) == cBytes:
      if start != -1:
        raise newException(ValueError, "more than one content-length")
      start = i+cBytes.len
    i = find(s, '\n'.byte, i)
    if i == -1:
      break
    inc i
  if start != -1:
    i = find(s, '\r'.byte, start)
    doAssert i != -1
    doAssert start <= i-1
    doAssert s[start] == ' '.byte
    return parseBigInt toOpenArray(s, start+1, i-1)

when isMainModule:
  block:
    raisesAssertion(doAssert false)
    var raised = false
    try:
      raisesAssertion(doAssert true)
    except AssertionDefect:
      raised = true
    doAssert raised
  block content_len:
    doAssert contentLen(newSeq[byte]()) == -1
    doAssert contentLen(":foo: abc\r\n".toBytes) == -1
    doAssert contentLen("content-length: 100\r\n".toBytes) == 100
    doAssert contentLen("content-length: 00012345678\r\n".toBytes) == 12345678
    doAssert contentLen(":foo: abc\r\ncontent-length: 100\r\n".toBytes) == 100
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

  echo "ok"