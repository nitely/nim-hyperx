import std/strformat

template ones(n: untyped): uint = (1.uint shl n) - 1

const
  frmHeaderSize* = 9  # 9 bytes = 72 bits
  # XXX: settings max frame size (payload) can be from 2^14 to 2^24-1
  frmMaxPayloadSize* = 1'u32 shl 14
  frmSettingsMaxFrameSize* = 1'u32 shl 14  # + frmHeaderSize

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

type
  FrmFlags* = distinct uint8
  FrmFlag* = distinct uint8

func contains*(flags: FrmFlags, f: FrmFlag): bool {.inline.} =
  result = (flags.uint8 and f.uint8) > 0

func incl*(flags: var FrmFlags, f: FrmFlag) {.inline.} =
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

type
  FrmSid* = distinct uint32  #range[0 .. 31.ones.int]

proc `==` *(a, b: FrmSid): bool {.borrow.}

func `+=`*(a: var FrmSid, b: uint) {.inline.} =
  a = (a.uint + b).FrmSid

const
  frmsidMain* = 0x00'u32.FrmSid

type
  FrmPayloadLen* = uint32  # range[0 .. 24.ones.int]
  Frame* = ref object
    s: array[frmHeaderSize, byte]
    rawL: int8  # XXX remove

func newFrame*(): Frame {.inline.} =
  Frame()

func setRawBytes*(frm: Frame, data: string) =
  doAssert data.len <= frmHeaderSize
  for i in 0 .. data.len-1:
    frm.s[i] = data[i].byte
  frm.rawL = data.len.int8

# XXX remove
func rawLen*(frm: Frame): int {.inline.} =
  frm.rawL

func len*(frm: Frame): int {.inline.} =
  frmHeaderSize

func rawBytesPtr*(frm: Frame): ptr byte =
  addr frm.s[0]

func clear*(frm: Frame) {.inline.} =
  for i in 0 .. frm.s.len-1:
    frm.s[i] = 0
  frm.rawL = 0

func setPayloadLen*(frm: Frame, n: FrmPayloadLen) {.inline.} =
  doAssert n <= 24.ones.uint
  frm.s[0] = ((n.uint shr 16) and 8.ones).byte
  frm.s[1] = ((n.uint shr 8) and 8.ones).byte
  frm.s[2] = (n.uint and 8.ones).byte

func setTyp*(frm: Frame, t: FrmTyp) {.inline.} =
  frm.s[3] = t.uint8

func setFlags*(frm: Frame, f: FrmFlags) {.inline.} =
  frm.s[4] = f.uint8

func setSid*(frm: Frame, sid: FrmSid) {.inline.} =
  ## Set the stream ID
  frm.s[5] = ((sid.uint shr 24) and 8.ones).byte
  frm.s[6] = ((sid.uint shr 16) and 8.ones).byte
  frm.s[7] = ((sid.uint shr 8) and 8.ones).byte
  frm.s[8] = (sid.uint and 8.ones).byte

func payloadLen*(frm: Frame): FrmPayloadLen {.inline.} =
  # XXX: validate this is equal to frm.s.len-frmHeaderSize on read
  result += frm.s[0].uint32 shl 16
  result += frm.s[1].uint32 shl 8
  result += frm.s[2].uint32
  doAssert result <= 24.ones.uint

func typ*(frm: Frame): FrmTyp {.inline.} =
  result = frm.s[3].FrmTyp

func flags*(frm: Frame): var FrmFlags {.inline.} =
  result = frm.s[4].FrmFlags

func sid*(frm: Frame): FrmSid {.inline.} =
  result += frm.s[5].uint shl 24
  result += frm.s[6].uint shl 16
  result += frm.s[7].uint shl 8
  result += frm.s[8].uint

#func add*(frm: Frame, payload: openArray[byte]) {.inline.} =
#  frm.s.add payload
#  frm.setPayloadLen FrmPayloadLen(frm.rawLen-frmHeaderSize)

#template payload*(frm: Frame): untyped =
#  toOpenArray(frm.s, frmHeaderSize, frm.s.len-1)

func rawStr*(frm: Frame): string =
  for b in frm.s:
    result.add b.char

func `$`*(frm: Frame): string =
  result = &"""
===Frame===
sid: {$frm.sid.int}
typ: {$frm.typ.int}
ack: {$(frmfAck in frm.flags)}
payload len: {$frm.payloadLen.int}
==========="""

func toString*(frm: Frame, payload: seq[byte]): string =
  result = "===Payload==="
  case frm.typ
  of frmtGoAway:
    var lastStreamId = 0.uint
    lastStreamId += payload[0].uint shl 24
    lastStreamId += payload[1].uint shl 16
    lastStreamId += payload[2].uint shl 8
    lastStreamId += payload[3].uint
    result.add &"\nLast-Stream-ID {$lastStreamId}"
    var errCode = 0.uint
    errCode += payload[4].uint shl 24
    errCode += payload[5].uint shl 16
    errCode += payload[6].uint shl 8
    errCode += payload[7].uint
    result.add &"\nError Code {$errCode}"
  of frmtWindowUpdate:
    var wsIncrement = 0.uint
    wsIncrement += payload[0].uint shl 24
    wsIncrement += payload[1].uint shl 16
    wsIncrement += payload[2].uint shl 8
    wsIncrement += payload[3].uint
    result.add &"\nWindow Size Increment {$wsIncrement}"
  of frmtSettings:
    if payload.len mod 6 != 0:
      result.add "\nbad payload"
      return
    var i = 0
    for _ in 0 .. int(payload.len div 6)-1:
      var iden = 0.uint
      iden += payload[i].uint shl 8
      iden += payload[i+1].uint
      result.add &"\nIdentifier {$iden}"
      var value = 0.uint
      value += payload[i+2].uint shl 24
      value += payload[i+3].uint shl 16
      value += payload[i+4].uint shl 8
      value += payload[i+5].uint
      result.add &"\nValue {$value}"
      i += 6
  else:
    result.add "\nUnimplemented debug"
  result.add "\n============="
