## Exception types

# https://httpwg.org/specs/rfc9113.html#ErrorCodes
# XXX HyperxErrCode
type
  ErrorCode* = distinct uint8
const
  errNoError* = 0x00.ErrorCode
  errProtocolError* = 0x01.ErrorCode
  errInternalError* = 0x02.ErrorCode
  errFlowControlError* = 0x03.ErrorCode
  errSettingsTimeout* = 0x04.ErrorCode
  errStreamClosed* = 0x05.ErrorCode
  errFrameSizeError* = 0x06.ErrorCode
  errRefusedStream* = 0x07.ErrorCode
  errCancel* = 0x08.ErrorCode
  errCompressionError* = 0x09.ErrorCode
  errConnectError* = 0x0a.ErrorCode
  errEnhanceYourCalm* = 0x0b.ErrorCode
  errInadequateSecurity* = 0x0c.ErrorCode
  errHttp11Required* = 0x0d.ErrorCode
  errUnknown = 0xff.ErrorCode  # not in the spec

proc `==`*(a, b: ErrorCode): bool {.borrow.}

func `$`(errCode: ErrorCode): string {.raises: [].} =
  case errCode
  of errNoError: "NO_ERROR"
  of errProtocolError: "PROTOCOL_ERROR"
  of errInternalError: "INTERNAL_ERROR"
  of errFlowControlError: "FLOW_CONTROL_ERROR"
  of errSettingsTimeout: "SETTINGS_TIMEOUT"
  of errStreamClosed: "STREAM_CLOSED"
  of errFrameSizeError: "FRAME_SIZE_ERROR"
  of errRefusedStream: "REFUSED_STREAM"
  of errCancel: "CANCEL"
  of errCompressionError: "COMPRESSION_ERROR"
  of errConnectError: "CONNECT_ERROR"
  of errEnhanceYourCalm: "ENHANCE_YOUR_CALM"
  of errInadequateSecurity: "INADEQUATE_SECURITY"
  of errHttp11Required: "HTTP_1_1_REQUIRED"
  else: "UNKNOWN ERROR CODE"

func toErrorCode(e: uint32): ErrorCode {.raises: [].} =
  if e in errNoError.uint32 .. errHttp11Required.uint32:
    return e.ErrorCode
  return errUnknown

# XXX remove ConnError and StrmError; expose code in Hyperx*
type
  HyperxError* = object of CatchableError
  HyperxConnError* = object of HyperxError
  HyperxStrmError* = object of HyperxError
  ConnClosedError* = object of HyperxConnError
  ConnError* = object of HyperxConnError
    code*: ErrorCode
  StrmError* = object of HyperxStrmError
    code*: ErrorCode
  GotRstError* = object of StrmError
  QueueError* = object of HyperxError
  QueueClosedError* = object of QueueError

func newHyperxConnError*(msg: string): ref HyperxConnError {.raises: [].} =
  result = (ref HyperxConnError)(msg: msg)

func newConnClosedError*(): ref ConnClosedError {.raises: [].} =
  result = (ref ConnClosedError)(msg: "Connection Closed")

func newConnError*(errCode: ErrorCode): ref ConnError {.raises: [].} =
  result = (ref ConnError)(code: errCode, msg: "Connection Error: " & $errCode)

func newStrmError*(errCode: ErrorCode): ref StrmError {.raises: [].} =
  result = (ref StrmError)(code: errCode, msg: "Stream Error: " & $errCode)

func newStrmError*(errCode: uint32): ref StrmError {.raises: [].} =
  result = newStrmError(errCode.toErrorCode)

func newGotRstError*(errCode: ErrorCode): ref GotRstError {.raises: [].} =
  result = (ref GotRstError)(code: errCode, msg: "Got Rst Error: " & $errCode)

func newGotRstError*(errCode: uint32): ref GotRstError {.raises: [].} =
  result = newGotRstError(errCode.toErrorCode)
