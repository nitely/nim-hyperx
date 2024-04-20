## Exception types

# https://httpwg.org/specs/rfc9113.html#ErrorCodes
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

# XXX prefix Hyperx
type
  HyperxError* = object of CatchableError
  HyperxConnectionError* = object of HyperxError
  ConnectionClosedError* = object of HyperxConnectionError
  InternalOsError* = object of HyperxConnectionError
  InternalSslError* = object of InternalOsError
  ConnError* = object of HyperxConnectionError
    code*: ErrorCode
  StrmError* = object of HyperxError
    code*: ErrorCode
  HyperxConnError* = HyperxConnectionError
  HyperxStrmError* = StrmError

func newConnError*(errCode: ErrorCode): ref ConnError {.raises: [].} =
  result = (ref ConnError)(code: errCode, msg: "Connection Error: " & $errCode)

func newConnClosedError*(): ref ConnectionClosedError {.raises: [].} =
  result = (ref ConnectionClosedError)(msg: "Connection Closed")

func newStrmError*(errCode: ErrorCode): ref StrmError {.raises: [].} =
  result = (ref StrmError)(code: errCode, msg: "Stream Error: " & $errCode)

func newInternalOsError*(msg: string): ref InternalOsError {.raises: [].} =
  result = (ref InternalOsError)(msg: msg)

func newHyperxConnectionError*(msg: string): ref HyperxConnectionError {.raises: [].} =
  result = (ref HyperxConnectionError)(msg: msg)
