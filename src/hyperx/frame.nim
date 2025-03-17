import std/strutils
import std/strformat

template ones(n: untyped): uint = (1.uint shl n) - 1

template assignAt(s: var seq[byte], i: int, x: uint32): untyped =
  s[i+0] = ((x shr 24) and 8.ones).byte
  s[i+1] = ((x shr 16) and 8.ones).byte
  s[i+2] = ((x shr 8) and 8.ones).byte
  s[i+3] = (x and 8.ones).byte

template u32At(s: openArray[byte], i: int, x: var uint32): untyped =
  x = 0
  x += s[i+0].uint32 shl 24
  x += s[i+1].uint32 shl 16
  x += s[i+2].uint32 shl 8
  x += s[i+3].uint32

proc clearBit(v: var uint32, bit: int) {.raises: [].} =
  v = v and not (1'u32 shl bit)

const
  frmHeaderSize* = 9  # 9 bytes = 72 bits
  frmPrioritySize* = 5
  frmPaddingSize* = 1
  frmRstStreamSize = 4
  frmSettingsAckSize = 0
  frmSettingsSize* = 6
  frmPingSize = 8
  frmWindowUpdateSize = 4
  frmGoAwaySize = 8

type
  FrmTyp* = distinct uint8

proc `==` *(a, b: FrmTyp): bool {.borrow.}

const
  frmtData* = 0x00'u8.FrmTyp
  frmtHeaders* = 0x01'u8.FrmTyp
  frmtPriority* = 0x02'u8.FrmTyp
  frmtRstStream* = 0x03'u8.FrmTyp
  frmtSettings* = 0x04'u8.FrmTyp
  frmtPushPromise* = 0x05'u8.FrmTyp
  frmtPing* = 0x06'u8.FrmTyp
  frmtGoAway* = 0x07'u8.FrmTyp
  frmtWindowUpdate* = 0x08'u8.FrmTyp
  frmtContinuation* = 0x09'u8.FrmTyp

const
  frmPaddedTypes* = {frmtHeaders, frmtPushPromise, frmtData}

func isUnknown*(typ: FrmTyp): bool =
  typ.uint8 notin 0x00'u8 .. 0x09'u8

type
  FrmFlags* = distinct uint8
  FrmFlag* = distinct uint8

func contains*(flags: FrmFlags, f: FrmFlag): bool {.raises: [].} =
  result = (flags.uint8 and f.uint8) > 0

func incl*(flags: var FrmFlags, f: FrmFlag) {.raises: [].} =
  flags = (flags.uint8 xor f.uint8).FrmFlags

const
  frmfAck* = 0x01'u8.FrmFlag
  frmfEndHeaders* = 0x04'u8.FrmFlag
  frmfEndStream* = 0x01'u8.FrmFlag
  frmfPadded* = 0x08'u8.FrmFlag
  frmfPriority* = 0x20'u8.FrmFlag

type
  FrmErrCode* = distinct uint8

const
  frmeNoError* = 0x00'u8.FrmErrCode
  frmeProtocolError* = 0x01'u8.FrmErrCode
  frmeInternalError* = 0x02'u8.FrmErrCode
  frmeFlowControlError* = 0x03'u8.FrmErrCode
  frmeSettingsTimeout* = 0x04'u8.FrmErrCode
  frmeStreamClosed* = 0x05'u8.FrmErrCode
  frmeFrameSizeError* = 0x06'u8.FrmErrCode
  frmeRefusedStream* = 0x07'u8.FrmErrCode
  frmeCancel* = 0x08'u8.FrmErrCode
  frmeCompressionError* = 0x09'u8.FrmErrCode
  frmeConnectError* = 0x0a'u8.FrmErrCode
  frmeEnhanceYourCalm* = 0x0b'u8.FrmErrCode
  frmeInadequateSecurity* = 0x0c'u8.FrmErrCode
  frmeHttp11Required* = 0x0d'u8.FrmErrCode

type
  FrmSetting* = distinct uint8

const
  frmsHeaderTableSize* = 0x01'u8.FrmSetting
  frmsEnablePush* = 0x02'u8.FrmSetting
  frmsMaxConcurrentStreams* = 0x03'u8.FrmSetting
  frmsInitialWindowSize* = 0x04'u8.FrmSetting
  frmsMaxFrameSize* = 0x05'u8.FrmSetting
  frmsMaxHeaderListSize* = 0x06'u8.FrmSetting
  frmsNoPriority* = 0x09'u8.FrmSetting
  frmsAllSettings = {
    frmsHeaderTableSize,
    frmsEnablePush,
    frmsMaxConcurrentStreams,
    frmsInitialWindowSize,
    frmsMaxFrameSize,
    frmsMaxHeaderListSize,
    frmsNoPriority
  }

type
  FrmSid* = distinct uint32  #range[0 .. 31.ones.int]

proc `==`*(a, b: FrmSid): bool {.borrow.}
proc `+=`*(a: var FrmSid, b: FrmSid) {.borrow.}
proc `<`*(a, b: FrmSid): bool {.borrow.}
proc `<=`*(a, b: FrmSid): bool {.borrow.}

#func `+=`*(a: var FrmSid, b: uint) {.raises: [].} =
#  a = (a.uint + b).FrmSid

const
  frmSidMain* = 0x00'u32.FrmSid

type
  FrmPayloadLen* = uint32  # range[0 .. 24.ones.int]
  Frame* = ref object
    s*: seq[byte]

func newFrame*(payloadLen = 0): Frame {.raises: [].} =
  Frame(s: newSeq[byte](frmHeaderSize+payloadLen))

func newEmptyFrame*(): Frame {.raises: [].} =
  Frame(s: newSeq[byte]())

func isEmpty*(frm: Frame): bool {.raises: [].} =
  frm.s.len == 0

func rawBytesPtr*(frm: Frame): ptr byte {.raises: [].} =
  addr frm.s[0]

func rawPayloadBytesPtr*(frm: Frame): ptr byte {.raises: [].} =
  addr frm.s[frmHeaderSize]

func clear*(frm: Frame) {.raises: [].} =
  frm.s.setLen frmHeaderSize
  for i in 0 .. frm.s.len-1:
    frm.s[i] = 0

func len*(frm: Frame): int {.raises: [].} =
  frm.s.len

template payload*(frm: Frame): untyped =
  toOpenArray(frm.s, frmHeaderSize, frm.s.len-1)

func grow*(frm: Frame, size: int) {.raises: [].} =
  frm.s.setLen frm.s.len+size

func shrink*(frm: Frame, size: int) {.raises: [].} =
  doAssert frm.s.len >= size
  doAssert frm.s.len-size >= frmHeaderSize
  frm.s.setLen frm.s.len-size

func payloadLen*(frm: Frame): FrmPayloadLen {.raises: [].} =
  ## This can include padding and prio len,
  ## and be greater than frm.payload.len
  # XXX: validate this is equal to frm.s.len-frmHeaderSize on read
  result = FrmPayloadLen(0)
  result += frm.s[0].uint32 shl 16
  result += frm.s[1].uint32 shl 8
  result += frm.s[2].uint32
  doAssert result <= 24.ones.uint

func typ*(frm: Frame): FrmTyp {.raises: [].} =
  result = frm.s[3].FrmTyp

# XXX mflags
func flags*(frm: Frame): var FrmFlags {.raises: [].} =
  result = frm.s[4].FrmFlags

# XXX flags
func flags2(frm: Frame): FrmFlags {.raises: [].} =
  result = frm.s[4].FrmFlags

func sid*(frm: Frame): FrmSid {.raises: [].} =
  var sid = 0'u32
  u32At(frm.s, 5, sid)
  sid.clearBit 31
  return FrmSid sid

func setPayloadLen*(frm: Frame, n: FrmPayloadLen) {.raises: [].} =
  doAssert n <= 24.ones.uint
  frm.s[0] = ((n.uint shr 16) and 8.ones).byte
  frm.s[1] = ((n.uint shr 8) and 8.ones).byte
  frm.s[2] = (n.uint and 8.ones).byte

func setTyp*(frm: Frame, t: FrmTyp) {.raises: [].} =
  frm.s[3] = t.uint8

func setFlags*(frm: Frame, f: FrmFlags) {.raises: [].} =
  frm.s[4] = f.uint8

func setSid*(frm: Frame, sid: FrmSid) {.raises: [].} =
  ## Set the stream ID
  frm.s.assignAt(5, sid.uint32)

func add*(frm: Frame, payload: openArray[byte]) {.raises: [].} =
  frm.s.add payload
  frm.setPayloadLen frm.payload.len.FrmPayloadLen

func isValidSize*(frm: Frame, size: int): bool {.raises: [].} =
  result = case frm.typ
  of frmtRstStream:
    size == frmRstStreamSize
  of frmtPriority:
    size == frmPrioritySize
  of frmtSettings:
    if frmfAck in frm.flags:
      size == frmSettingsAckSize
    else:
      size mod frmSettingsSize == 0
  of frmtPing:
    size == frmPingSize
  of frmtWindowUpdate:
    size == frmWindowUpdateSize
  else:
    true

func isPadded*(frm: Frame): bool {.raises: [].} =
  frmfPadded in frm.flags and frm.typ in frmPaddedTypes

func hasPrio*(frm: Frame): bool {.raises: [].} =
  frmfPriority in frm.flags and frm.typ == frmtHeaders

func newGoAwayFrame*(
  lastSid: FrmSid, errorCode: FrmErrCode
): Frame {.raises: [].} =
  result = newFrame(frmGoAwaySize)
  result.setTyp frmtGoAway
  result.setPayloadLen frmGoAwaySize.FrmPayloadLen
  result.s.assignAt(frmHeaderSize, lastSid.uint32)
  result.s.assignAt(frmHeaderSize+4, errorCode.uint32)

func newRstStreamFrame*(
  sid: FrmSid,
  errorCode: FrmErrCode
): Frame {.raises: [].} =
  result = newFrame(frmRstStreamSize)
  result.setTyp frmtRstStream
  result.setSid sid
  result.setPayloadLen frmRstStreamSize.FrmPayloadLen
  result.s.assignAt(frmHeaderSize, errorCode.uint32)

func newWindowUpdateFrame*(
  sid: FrmSid,
  increment: int
): Frame {.raises: [].} =
  result = newFrame(frmWindowUpdateSize)
  result.setTyp frmtWindowUpdate
  result.setSid sid
  result.setPayloadLen frmWindowUpdateSize.FrmPayloadLen
  result.s.assignAt(frmHeaderSize, increment.uint32)

func newSettingsFrame*(ack = false): Frame {.raises: [].} =
  result = newFrame()
  result.setTyp frmtSettings
  result.setSid frmSidMain
  if ack:
    result.flags.incl frmfAck

func newPingFrame*(
  ackPayload: openArray[byte] = []
): Frame {.raises: [].} =
  doAssert ackPayload.len == 0 or ackPayload.len == frmPingSize
  result = newFrame(frmPingSize)
  result.setTyp frmtPing
  result.setSid frmSidMain
  result.setPayloadLen frmPingSize.FrmPayloadLen
  if ackPayload.len > 0:
    result.flags.incl frmfAck
    for i in 0 .. frmPingSize-1:
      result.s[frmHeaderSize+i] = ackPayload[i]

func newPingFrame*(data: uint32): Frame {.raises: [].} =
  result = newFrame(frmPingSize)
  result.setTyp frmtPing
  result.setSid frmSidMain
  result.setPayloadLen frmPingSize.FrmPayloadLen
  result.s.assignAt(frmHeaderSize, data)

func addSetting*(
  frm: Frame,
  id: FrmSetting,
  value: uint32
) {.raises: [].} =
  doAssert frm.typ == frmtSettings
  doAssert frmfAck notin frm.flags2
  let i = frm.len
  frm.grow frmSettingsSize
  frm.setPayloadLen frm.payload.len.FrmPayloadLen
  frm.s[i] = 0.byte
  frm.s[i+1] = id.byte
  frm.s.assignAt(i+2, value)

iterator settings*(frm: Frame): (FrmSetting, uint32) {.inline, raises: [].} =
  # https://httpwg.org/specs/rfc9113.html#SettingFormat
  #doAssert frm.payload.len mod frmSettingsSize == 0
  var i = frmHeaderSize
  var id = 0'u16
  # need to return last value for each ID
  var skip = default(array[7, int32])
  while i < frm.len:
    id = 0'u16
    id += frm.s[i].uint16 shl 8
    id += frm.s[i+1].uint16
    if id.FrmSetting in frmsAllSettings:
      skip[id.int] += 1
    i += frmSettingsSize
  i = frmHeaderSize
  var value = 0'u32
  while i < frm.len:
    id = 0'u16
    id += frm.s[i].uint16 shl 8
    id += frm.s[i+1].uint16
    if id.FrmSetting in frmsAllSettings:
      dec skip[id.int]
      if skip[id.int] == 0:
        value = 0'u32
        u32At(frm.s, i+2, value)
        yield (id.FrmSetting, value)
    # else skip
    i += frmSettingsSize

func prioDependency*(prio: openArray[byte]): FrmSid {.raises: [].} =
  var sid = 0'u32
  u32At(prio, 0, sid)
  sid.clearBit 31
  return FrmSid sid

func strmDependency*(frm: Frame): FrmSid {.raises: [].} =
  doAssert frm.typ == frmtPriority
  var sid = 0'u32
  u32At(frm.s, frmHeaderSize, sid)
  sid.clearBit 31
  return FrmSid sid

func windowSizeInc*(frm: Frame): uint32 {.raises: [].} =
  doAssert frm.typ == frmtWindowUpdate
  u32At(frm.s, frmHeaderSize, result)
  result.clearBit 31  # clear reserved byte

func errCode*(frm: Frame): uint32 {.raises: [].} =
  result = 0
  case frm.typ
  of frmtRstStream:
    u32At(frm.s, frmHeaderSize, result)
  of frmtGoAway:
    u32At(frm.s, frmHeaderSize+4, result)
  else:
    doAssert false

func pingData*(frm: Frame): uint32 {.raises: [].} =
  # note we ignore the last 4 bytes
  doAssert frm.typ == frmtPing
  u32At(frm.s, frmHeaderSize, result)

func lastStreamId*(frm: Frame): uint32 =
  doAssert frm.typ == frmtGoAway
  u32At(frm.s, frmHeaderSize, result)
  result.clearBit 31

func `$`*(frm: Frame): string {.raises: [].} =
  result = fmt"""
    ===Frame===
    sid: {$frm.sid.int}
    typ: {$frm.typ.int}
    ack: {$(frmfAck in frm.flags)}
    endStrm: {$(frmfEndStream in frm.flags)}
    payload len: {$frm.payloadLen.int}
    ===========""".unindent

func debugPayload*(frm: Frame): string {.raises: [].} =
  result = ""
  var i = frmHeaderSize
  result.add "===Payload==="
  case frm.typ
  of frmtRstStream:
    var errCode = 0'u32
    u32At(frm.s, i, errCode)
    result.add fmt("\nError Code {$errCode}")
  of frmtGoAway:
    var lastStreamId = 0'u32
    u32At(frm.s, i, lastStreamId)
    result.add fmt("\nLast-Stream-ID {$lastStreamId}")
    var errCode = 0'u32
    u32At(frm.s, i+4, errCode)
    result.add fmt("\nError Code {$errCode}")
  of frmtWindowUpdate:
    var wsIncrement = 0'u32
    u32At(frm.s, i, wsIncrement)
    result.add fmt("\nWindow Size Increment {$wsIncrement}")
  of frmtSettings:
    if frm.payloadLen.int mod 6 != 0:
      result.add "\nbad payload"
      return
    for _ in 0 .. int(frm.payloadLen.int div 6)-1:
      var iden = 0.uint
      iden += frm.s[i].uint shl 8
      iden += frm.s[i+1].uint
      result.add fmt("\nIdentifier {$iden}")
      var value = 0'u32
      u32At(frm.s, i+2, value)
      result.add fmt("\nValue {$value}")
      i += 6
  of frmtPing:
    var value = 0
    for x in frm.payload:
      value += x.int
    result.add fmt("\nPing {$value}")
  of frmtData:
    if frm.payload.len > 0:
      result.add "\n"
      var x = 0
      for byt in frm.payload:
        result.add byt.char
        inc x
        if x == 10:
          break
      if frm.payload.len > 10:
        result.add "[truncated]"
  else:
    result.add "\nUnimplemented debug"
  result.add "\n============="

when isMainModule:
  block:
    var frm = newFrame()
    frm.setTyp frmtData
    doAssert isValidSize(frm, 123)
    frm.setTyp frmtHeaders
    doAssert isValidSize(frm, 123)
    frm.setTyp frmtGoAway
    doAssert isValidSize(frm, 123)
    frm.setTyp frmtRstStream
    doAssert isValidSize(frm, 4)
    doAssert not isValidSize(frm, 3)
    doAssert not isValidSize(frm, 5)
    frm.setTyp frmtPriority
    doAssert isValidSize(frm, 5)
    doAssert not isValidSize(frm, 4)
    doAssert not isValidSize(frm, 6)
    frm.setTyp frmtPing
    doAssert isValidSize(frm, 8)
    doAssert not isValidSize(frm, 7)
    doAssert not isValidSize(frm, 9)
    frm.setTyp frmtWindowUpdate
    doAssert isValidSize(frm, 4)
    doAssert not isValidSize(frm, 3)
    doAssert not isValidSize(frm, 5)
  block:
    var frm = newFrame()
    frm.setTyp frmtSettings
    doAssert isValidSize(frm, 0)
    doAssert isValidSize(frm, 6)
    doAssert isValidSize(frm, 12)
    doAssert isValidSize(frm, 18)
    doAssert not isValidSize(frm, 1)
    doAssert not isValidSize(frm, 5)
    doAssert not isValidSize(frm, 7)
    frm.setFlags frmfAck.FrmFlags
    doAssert isValidSize(frm, 0)
    doAssert not isValidSize(frm, 1)
    doAssert not isValidSize(frm, 6)
    doAssert not isValidSize(frm, 12)

  echo "ok"
