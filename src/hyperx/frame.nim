import std/strutils
import std/strformat
import ./utils

template ones(n: untyped): uint = (1.uint shl n) - 1

const
  frmHeaderSize* = 9  # 9 bytes = 72 bits
  frmPrioritySize* = 5
  frmPaddingSize* = 1
  frmRstStreamSize = 4
  frmSettingsAckSize = 0
  frmSettingsSize = 6
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

type
  FrmFlags* = distinct uint8
  FrmFlag* = distinct uint8

func contains*(flags: FrmFlags, f: FrmFlag): bool {.inline, raises: [].} =
  result = (flags.uint8 and f.uint8) > 0

func incl*(flags: var FrmFlags, f: FrmFlag) {.inline, raises: [].} =
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
  frmsAllSettings = {
    frmsHeaderTableSize,
    frmsEnablePush,
    frmsMaxConcurrentStreams,
    frmsInitialWindowSize,
    frmsMaxFrameSize,
    frmsMaxHeaderListSize
  }

type
  FrmSid* = distinct uint32  #range[0 .. 31.ones.int]

proc `==`*(a, b: FrmSid): bool {.borrow.}

func `+=`*(a: var FrmSid, b: uint) {.inline, raises: [].} =
  a = (a.uint + b).FrmSid

proc clearBit(v: var FrmSid, bit: int) {.inline, raises: [].} =
  v = FrmSid(v.uint and not (1'u32 shl bit))

const
  frmSidMain* = 0x00'u32.FrmSid

type
  FrmPayloadLen* = uint32  # range[0 .. 24.ones.int]
  Frame* = ref object
    s*: seq[byte]

func newFrame*(payloadLen = 0): Frame {.inline, raises: [].} =
  Frame(s: newSeq[byte](frmHeaderSize+payloadLen))

func rawBytesPtr*(frm: Frame): ptr byte =
  addr frm.s[0]

func rawPayloadBytesPtr*(frm: Frame): ptr byte =
  addr frm.s[frmHeaderSize]

func clear*(frm: Frame) {.inline, raises: [].} =
  frm.s.setLen frmHeaderSize
  for i in 0 .. frm.s.len-1:
    frm.s[i] = 0

func len*(frm: Frame): int {.inline, raises: [].} =
  frm.s.len

template payload*(frm: Frame): untyped =
  toOpenArray(frm.s, frmHeaderSize, frm.s.len-1)

func grow*(frm: Frame, size: int) {.inline, raises: [].} =
  frm.s.setLen frm.s.len+size

func shrink*(frm: Frame, size: int) {.inline, raises: [].} =
  doAssert frm.s.len >= size
  doAssert frm.s.len-size >= frmHeaderSize
  frm.s.setLen frm.s.len-size

func payloadLen*(frm: Frame): FrmPayloadLen {.inline, raises: [].} =
  # XXX: validate this is equal to frm.s.len-frmHeaderSize on read
  result += frm.s[0].uint32 shl 16
  result += frm.s[1].uint32 shl 8
  result += frm.s[2].uint32
  doAssert result <= 24.ones.uint

func typ*(frm: Frame): FrmTyp {.inline, raises: [].} =
  result = frm.s[3].FrmTyp

func flags*(frm: Frame): var FrmFlags {.inline, raises: [].} =
  result = frm.s[4].FrmFlags

func sid*(frm: Frame): FrmSid {.inline, raises: [].} =
  result += frm.s[5].uint shl 24
  result += frm.s[6].uint shl 16
  result += frm.s[7].uint shl 8
  result += frm.s[8].uint
  result.clearBit 31  # clear reserved byte

func setHeader*(frm: Frame, data: string) {.inline, raises: [].} =
  doAssert data.len == frmHeaderSize
  for i in 0 .. data.len-1:
    frm.s[i] = data[i].byte

func setPayloadLen*(frm: Frame, n: FrmPayloadLen) {.inline, raises: [].} =
  doAssert n <= 24.ones.uint
  frm.s[0] = ((n.uint shr 16) and 8.ones).byte
  frm.s[1] = ((n.uint shr 8) and 8.ones).byte
  frm.s[2] = (n.uint and 8.ones).byte

func setTyp*(frm: Frame, t: FrmTyp) {.inline, raises: [].} =
  frm.s[3] = t.uint8

func setFlags*(frm: Frame, f: FrmFlags) {.inline, raises: [].} =
  frm.s[4] = f.uint8

func setSid*(frm: Frame, sid: FrmSid) {.inline, raises: [].} =
  ## Set the stream ID
  frm.s[5] = ((sid.uint shr 24) and 8.ones).byte
  frm.s[6] = ((sid.uint shr 16) and 8.ones).byte
  frm.s[7] = ((sid.uint shr 8) and 8.ones).byte
  frm.s[8] = (sid.uint and 8.ones).byte

func add*(frm: Frame, payload: openArray[byte]) {.inline, raises: [].} =
  frm.s.add payload
  frm.setPayloadLen frm.payload.len.FrmPayloadLen

func isValidSize*(frm: Frame, size: int): bool {.inline, raises: [].} =
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

template assignAt(s: var seq[byte], i: int, x: uint32): untyped =
  s[i+0] = ((x shr 24) and 8.ones).byte
  s[i+1] = ((x shr 16) and 8.ones).byte
  s[i+2] = ((x shr 8) and 8.ones).byte
  s[i+3] = (x and 8.ones).byte

func newGoAwayFrame*(
  lastSid, errorCode: int
): Frame {.inline, raises: [].} =
  result = newFrame(frmGoAwaySize)
  result.setTyp frmtGoAway
  result.setPayloadLen frmGoAwaySize.FrmPayloadLen
  result.s.assignAt(frmHeaderSize, lastSid.uint32)
  result.s.assignAt(frmHeaderSize+4, errorCode.uint32)

func newRstStreamFrame*(
  sid: FrmSid,
  errorCode: int
): Frame {.inline, raises: [].} =
  result = newFrame(frmRstStreamSize)
  result.setTyp frmtRstStream
  result.setSid sid
  result.setPayloadLen frmRstStreamSize.FrmPayloadLen
  result.s.assignAt(frmHeaderSize, errorCode.uint32)

func newWindowUpdateFrame*(
  sid: FrmSid,
  increment: int
): Frame {.inline, raises: [].} =
  result = newFrame(frmWindowUpdateSize)
  result.setTyp frmtWindowUpdate
  result.setSid sid
  result.setPayloadLen frmWindowUpdateSize.FrmPayloadLen
  result.s.assignAt(frmHeaderSize, increment.uint32)

func addSetting*(
  frm: Frame,
  id: FrmSetting,
  value: uint32
) {.inline, raises: [].} =
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
  var skip: array[7, int32]
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
        value += frm.s[i+2].uint32 shl 24
        value += frm.s[i+3].uint32 shl 16
        value += frm.s[i+4].uint32 shl 8
        value += frm.s[i+5].uint32
        yield (id.FrmSetting, value)
    # else skip
    i += frmSettingsSize

# XXX add padding field and padding as payload
#func setPadding*(frm: Frame, n: FrmPadding) {.inline.} =
#  doAssert frm.typ in {frmtData, frmtHeaders, frmtPushPromise}

#func add*(frm: Frame, payload: openArray[byte]) {.inline.} =
#  frm.s.add payload
#  frm.setPayloadLen FrmPayloadLen(frm.rawLen-frmHeaderSize)

#template payload*(frm: Frame): untyped =
#  toOpenArray(frm.s, frmHeaderSize, frm.s.len-1)

func `$`*(frm: Frame): string {.raises: [].} =
  untrackExceptions:
    result = fmt"""
      ===Frame===
      sid: {$frm.sid.int}
      typ: {$frm.typ.int}
      ack: {$(frmfAck in frm.flags)}
      payload len: {$frm.payloadLen.int}
      ===========""".unindent
    result.add "===Payload==="
    case frm.typ
    of frmtGoAway:
      var lastStreamId = 0.uint
      lastStreamId += frm.s[0].uint shl 24
      lastStreamId += frm.s[1].uint shl 16
      lastStreamId += frm.s[2].uint shl 8
      lastStreamId += frm.s[3].uint
      result.add fmt("\nLast-Stream-ID {$lastStreamId}")
      var errCode = 0.uint
      errCode += frm.s[4].uint shl 24
      errCode += frm.s[5].uint shl 16
      errCode += frm.s[6].uint shl 8
      errCode += frm.s[7].uint
      result.add fmt("\nError Code {$errCode}")
    of frmtWindowUpdate:
      var wsIncrement = 0.uint
      wsIncrement += frm.s[0].uint shl 24
      wsIncrement += frm.s[1].uint shl 16
      wsIncrement += frm.s[2].uint shl 8
      wsIncrement += frm.s[3].uint
      result.add fmt("\nWindow Size Increment {$wsIncrement}")
    of frmtSettings:
      if frm.payloadLen.int mod 6 != 0:
        result.add "\nbad payload"
        return
      var i = 0
      for _ in 0 .. int(frm.payloadLen.int div 6)-1:
        var iden = 0.uint
        iden += frm.s[i].uint shl 8
        iden += frm.s[i+1].uint
        result.add fmt("\nIdentifier {$iden}")
        var value = 0.uint
        value += frm.s[i+2].uint shl 24
        value += frm.s[i+3].uint shl 16
        value += frm.s[i+4].uint shl 8
        value += frm.s[i+5].uint
        result.add fmt("\nValue {$value}")
        i += 6
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
