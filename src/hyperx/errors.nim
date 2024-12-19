## Exception types

import ./frame

# https://httpwg.org/specs/rfc9113.html#ErrorCodes
type
  HyperxErrCode* = FrmErrCode
const
  hyxNoError* = frmeNoError
  hyxProtocolError* = frmeProtocolError
  hyxInternalError* = frmeInternalError
  hyxFlowControlError* = frmeFlowControlError
  hyxSettingsTimeout* = frmeSettingsTimeout
  hyxStreamClosed* = frmeStreamClosed
  hyxFrameSizeError* = frmeFrameSizeError
  hyxRefusedStream* = frmeRefusedStream
  hyxCancel* = frmeCancel
  hyxCompressionError* = frmeCompressionError
  hyxConnectError* = frmeConnectError
  hyxEnhanceYourCalm* = frmeEnhanceYourCalm
  hyxInadequateSecurity* = frmeInadequateSecurity
  hyxHttp11Required* = frmeHttp11Required
  hyxUnknown = 0xff.HyperxErrCode  # not in the spec

proc `==`*(a, b: HyperxErrCode): bool {.borrow.}

func `$`(errCode: HyperxErrCode): string {.raises: [].} =
  case errCode
  of hyxNoError: "NO_ERROR"
  of hyxProtocolError: "PROTOCOL_ERROR"
  of hyxInternalError: "INTERNAL_ERROR"
  of hyxFlowControlError: "FLOW_CONTROL_ERROR"
  of hyxSettingsTimeout: "SETTINGS_TIMEOUT"
  of hyxStreamClosed: "STREAM_CLOSED"
  of hyxFrameSizeError: "FRAME_SIZE_ERROR"
  of hyxRefusedStream: "REFUSED_STREAM"
  of hyxCancel: "CANCEL"
  of hyxCompressionError: "COMPRESSION_ERROR"
  of hyxConnectError: "CONNECT_ERROR"
  of hyxEnhanceYourCalm: "ENHANCE_YOUR_CALM"
  of hyxInadequateSecurity: "INADEQUATE_SECURITY"
  of hyxHttp11Required: "HTTP_1_1_REQUIRED"
  else: "UNKNOWN ERROR CODE"

func toErrorCode(e: uint32): HyperxErrCode {.raises: [].} =
  if e in hyxNoError.uint32 .. hyxHttp11Required.uint32:
    return e.HyperxErrCode
  return hyxUnknown

type
  HyperxErrTyp* = enum
    hyxLocalErr, hyxRemoteErr
  HyperxError* = object of CatchableError
    typ*: HyperxErrTyp
    code*: HyperxErrCode
  HyperxConnError* = object of HyperxError
  HyperxStrmError* = object of HyperxError
  ConnClosedError* = object of HyperxConnError
  GracefulShutdownError* = object of HyperxConnError
  QueueClosedError* = object of HyperxError

func newConnClosedError*: ref ConnClosedError {.raises: [].} =
  result = (ref ConnClosedError)(typ: hyxLocalErr, code: hyxInternalError, msg: "Connection Closed")

func newConnError*(msg: string, parent: ref Exception = nil): ref HyperxConnError {.raises: [].} =
  result = (ref HyperxConnError)(
    typ: hyxLocalErr, code: hyxInternalError, msg: msg, parent: parent
  )

func newConnError*(
  errCode: HyperxErrCode, typ = hyxLocalErr, parent: ref Exception = nil
): ref HyperxConnError {.raises: [].} =
  result = (ref HyperxConnError)(
    typ: typ, code: errCode, msg: "Connection Error: " & $errCode, parent: parent
  )

func newConnError*(
  errCode: uint32, typ = hyxLocalErr
): ref HyperxConnError {.raises: [].} =
  result = (ref HyperxConnError)(
    typ: typ,
    code: errCode.toErrorCode,
    msg: "Connection Error: " & $errCode.toErrorCode
  )

func newError*(
  err: ref HyperxConnError, parent: ref Exception = nil
): ref HyperxConnError {.raises: [].} =
  result = (ref HyperxConnError)(
    typ: err.typ, code: err.code, msg: err.msg, parent: parent
  )

func newStrmError*(
  errCode: HyperxErrCode, typ = hyxLocalErr, parent: ref Exception = nil
): ref HyperxStrmError {.raises: [].} =
  let msg = case typ
    of hyxLocalErr: "Stream Error: " & $errCode
    of hyxRemoteErr: "Got Rst Error: " & $errCode
  result = (ref HyperxStrmError)(
    typ: typ, code: errCode, msg: msg, parent: parent
  )

func newStrmError*(
  errCode: uint32, typ = hyxLocalErr
): ref HyperxStrmError {.raises: [].} =
  result = newStrmError(errCode.toErrorCode, typ)

func newError*(
  err: ref HyperxStrmError, parent: ref Exception = nil
): ref HyperxStrmError {.raises: [].} =
  result = (ref HyperxStrmError)(
    typ: err.typ, code: err.code, msg: err.msg, parent: parent
  )

func newErrorOrDefault*(
  err, default: ref HyperxStrmError
): ref HyperxStrmError {.raises: [].} =
  if err != nil:
    return newError(err)
  else:
    return default

func newGracefulShutdownError*(): ref GracefulShutdownError {.raises: [].} =
  result = (ref GracefulShutdownError)(
    code: hyxNoError, msg: "Connection Error: " & $hyxNoError
  )
