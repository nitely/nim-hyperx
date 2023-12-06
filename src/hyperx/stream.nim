import ./frame

# Section 5.1
type
  StreamState* = enum
    strmIdle
    strmOpen
    strmClosed
    strmReservedLocal
    strmReservedRemote
    strmHalfClosedLocal
    strmHalfClosedRemote
    strmInvalid
  StreamEvent* = enum
    seHeadersRecv
    seHeadersSend
    sePushPromiseRecv
    sePushPromiseSend
    seEndStreamRecv
    seEndStreamSend
    seRstStream
    sePriorityRecv
    sePrioritySend
    seWindowUpdateRecv
    seWindowUpdateSend
    seDataRecv
    seUnknown

const eventRecvAllowed* = {
  seHeadersRecv,
  sePushPromiseRecv,
  seEndStreamRecv,
  seRstStream,
  sePriorityRecv,
  seWindowUpdateRecv,
  seDataRecv
}

const frmRecvAllowed* = {
  frmtData,
  frmtHeaders,
  frmtPriority,
  frmtRstStream,
  frmtPushPromise,
  frmtWindowUpdate
}

# Section 5.1
func toNextStateRecv*(s: StreamState, e: StreamEvent): StreamState =
  doAssert e in eventRecvAllowed
  case s
  of strmIdle:
    case e:
    of seHeadersRecv: strmOpen
    of sePushPromiseRecv: strmReservedRemote
    of seEndStreamRecv: strmHalfClosedRemote
    of sePriorityRecv: strmIdle
    else: strmInvalid
  of strmOpen:
    case e
    of seEndStreamRecv: strmHalfClosedRemote
    of seRstStream: strmClosed
    else: strmOpen
  of strmClosed:
    case e
    of sePriorityRecv,
      seWindowUpdateRecv,
      seRstStream: strmClosed
    of sePushPromiseRecv: strmReservedRemote
    else: strmInvalid
  of strmReservedRemote:
    case e
    of seHeadersRecv: strmHalfClosedLocal
    of seRstStream: strmClosed
    of sePriorityRecv: strmReservedRemote
    else: strmInvalid
  of strmHalfClosedLocal:
    case e
    of seEndStreamRecv, seRstStream: strmClosed
    else: strmHalfClosedLocal
  of strmHalfClosedRemote:
    case e
    of seRstStream: strmClosed
    of seWindowUpdateRecv, sePriorityRecv: strmHalfClosedRemote
    else: strmInvalid
  of strmReservedLocal:
    doAssert false
    strmInvalid
  of strmInvalid:
    #doAssert false  # XXX uncomment when errors are handled
    strmInvalid

func toEventRecv*(frm: Frame): StreamEvent =
  doAssert frm.typ in frmRecvAllowed
  case frm.typ
  of frmtData:
    if frmfEndStream in frm.flags:
      seEndStreamRecv
    else:
      seDataRecv
  of frmtHeaders:
    if frmfEndStream in frm.flags:
      seEndStreamRecv
    else:
      seHeadersRecv
  of frmtPriority:
    sePriorityRecv
  of frmtRstStream:
    seRstStream
  of frmtPushPromise:
    sePushPromiseRecv
  of frmtWindowUpdate:
    seWindowUpdateRecv
  else:
    doAssert false
    seUnknown

func isAllowedToSend*(state: StreamState, frm: Frame): bool =
  ## Check if the stream is allowed to send the frame
  true

func isAllowedToRecv*(state: StreamState, frm: Frame): bool =
  ## Check if the stream is allowed to receive the frame
  # https://httpwg.org/specs/rfc9113.html#StreamStates
  case state
  of strmIdle:
    frm.typ in {frmtHeaders, frmtPriority}
  of strmReservedLocal:
    frm.typ in {frmtRstStream, frmtPriority, frmtWindowUpdate}
  of strmReservedRemote:
    frm.typ in {frmtHeaders, frmtRstStream, frmtPriority}
  of strmOpen, strmHalfClosedLocal:
    true
  of strmHalfClosedRemote:
    frm.typ in {frmtWindowUpdate, frmtPriority, frmtRstStream}
  of strmClosed:  # XXX only do minimal processing of frames
    true
  of strmInvalid: false
