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
func toNextStateRecv*(s: StreamState, e: StreamEvent): StreamState {.raises: [].} =
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
    doAssert false
    strmInvalid

func toEventRecv*(frm: Frame): StreamEvent {.raises: [].} =
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

func isAllowedToSend*(state: StreamState, frm: Frame): bool {.raises: [].} =
  ## Check if the stream is allowed to send the frame
  true

func isAllowedToRecv*(state: StreamState, frm: Frame): bool {.raises: [].} =
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

when isMainModule:
  import ./utils
  func frame(typ: FrmTyp, flags = 0.FrmFlags): Frame =
    result = newFrame()
    result.setTyp typ
    result.setFlags flags
  const allEvents = {
    seHeadersRecv,
    seHeadersSend,
    sePushPromiseRecv,
    sePushPromiseSend,
    seEndStreamRecv,
    seEndStreamSend,
    seRstStream,
    sePriorityRecv,
    sePrioritySend,
    seWindowUpdateRecv,
    seWindowUpdateSend,
    seDataRecv,
    seUnknown
  }
  const allFrames = {
    frmtData,
    frmtHeaders,
    frmtPriority,
    frmtRstStream,
    frmtSettings,
    frmtPushPromise,
    frmtPing,
    frmtGoAway,
    frmtWindowUpdate,
    frmtContinuation,
  }
  block:
    for ev in allEvents-eventRecvAllowed:
      raisesAssertion:
        discard toNextStateRecv(strmIdle, ev)
    raisesAssertion:
      discard toNextStateRecv(strmIdle, seHeadersSend)
    raisesAssertion:
      discard toNextStateRecv(strmIdle, sePushPromiseSend)
    raisesAssertion:
      discard toNextStateRecv(strmIdle, seEndStreamSend)
    raisesAssertion:
      discard toNextStateRecv(strmIdle, sePrioritySend)
    raisesAssertion:
      discard toNextStateRecv(strmIdle, seWindowUpdateSend)
    raisesAssertion:
      discard toNextStateRecv(strmIdle, seUnknown)
  block:
    doAssert toNextStateRecv(strmIdle, seHeadersRecv) == strmOpen
    doAssert toNextStateRecv(strmIdle, sePushPromiseRecv) == strmReservedRemote
    doAssert toNextStateRecv(strmIdle, seEndStreamRecv) == strmHalfClosedRemote
    doAssert toNextStateRecv(strmIdle, sePriorityRecv) == strmIdle
    for ev in eventRecvAllowed-{seHeadersRecv, sePushPromiseRecv, seEndStreamRecv, sePriorityRecv}:
      doAssert toNextStateRecv(strmIdle, ev) == strmInvalid
    doAssert toNextStateRecv(strmOpen, seEndStreamRecv) == strmHalfClosedRemote
    doAssert toNextStateRecv(strmOpen, seRstStream) == strmClosed
    doAssert toNextStateRecv(strmOpen, seDataRecv) == strmOpen
    for ev in eventRecvAllowed-{seEndStreamRecv, seRstStream}:
      doAssert toNextStateRecv(strmOpen, ev) == strmOpen
    doAssert toNextStateRecv(strmClosed, sePriorityRecv) == strmClosed
    doAssert toNextStateRecv(strmClosed, seWindowUpdateRecv) == strmClosed
    doAssert toNextStateRecv(strmClosed, seRstStream) == strmClosed
    doAssert toNextStateRecv(strmClosed, sePushPromiseRecv) == strmReservedRemote
    for ev in eventRecvAllowed-{sePriorityRecv,seWindowUpdateRecv,seRstStream,sePushPromiseRecv}:
      doAssert toNextStateRecv(strmClosed, ev) == strmInvalid
    doAssert toNextStateRecv(strmReservedRemote, seHeadersRecv) == strmHalfClosedLocal
    doAssert toNextStateRecv(strmReservedRemote, seRstStream) == strmClosed
    doAssert toNextStateRecv(strmReservedRemote, sePriorityRecv) == strmReservedRemote
    for ev in eventRecvAllowed-{seHeadersRecv,seRstStream,sePriorityRecv}:
      doAssert toNextStateRecv(strmReservedRemote, ev) == strmInvalid
    doAssert toNextStateRecv(strmHalfClosedLocal, seEndStreamRecv) == strmClosed
    doAssert toNextStateRecv(strmHalfClosedLocal, seRstStream) == strmClosed
    doAssert toNextStateRecv(strmHalfClosedLocal, seDataRecv) == strmHalfClosedLocal
    for ev in eventRecvAllowed-{seEndStreamRecv,seRstStream}:
      doAssert toNextStateRecv(strmHalfClosedLocal, ev) == strmHalfClosedLocal
    doAssert toNextStateRecv(strmHalfClosedRemote, seRstStream) == strmClosed
    doAssert toNextStateRecv(strmHalfClosedRemote, seWindowUpdateRecv) == strmHalfClosedRemote
    doAssert toNextStateRecv(strmHalfClosedRemote, sePriorityRecv) == strmHalfClosedRemote
    for ev in eventRecvAllowed-{seRstStream,seWindowUpdateRecv,sePriorityRecv}:
      doAssert toNextStateRecv(strmHalfClosedRemote, ev) == strmInvalid
    for ev in eventRecvAllowed:
      raisesAssertion:
        discard toNextStateRecv(strmReservedLocal, ev)
    for ev in eventRecvAllowed:
      raisesAssertion:
        discard toNextStateRecv(strmInvalid, ev)
  block:
    for frmTyp in allFrames-frmRecvAllowed:
      raisesAssertion:
        discard toEventRecv(frmTyp.frame)
    doAssert toEventRecv(frmtData.frame) == seDataRecv
    doAssert toEventRecv(frmtData.frame(frmfEndStream.FrmFlags)) == seEndStreamRecv
    doAssert toEventRecv(frmtHeaders.frame) == seHeadersRecv
    doAssert toEventRecv(frmtHeaders.frame(frmfEndStream.FrmFlags)) == seEndStreamRecv
    doAssert toEventRecv(frmtPriority.frame) == sePriorityRecv
    doAssert toEventRecv(frmtRstStream.frame) == seRstStream
    doAssert toEventRecv(frmtPushPromise.frame) == sePushPromiseRecv
    doAssert toEventRecv(frmtWindowUpdate.frame) == seWindowUpdateRecv
  block:
    doAssert isAllowedToRecv(strmIdle, frmtHeaders.frame)
    doAssert isAllowedToRecv(strmIdle, frmtPriority.frame)
    for frmTyp in allFrames-{frmtHeaders,frmtPriority}:
      doAssert(not isAllowedToRecv(strmIdle, frmTyp.frame))
    doAssert isAllowedToRecv(strmReservedLocal, frmtRstStream.frame)
    doAssert isAllowedToRecv(strmReservedLocal, frmtPriority.frame)
    doAssert isAllowedToRecv(strmReservedLocal, frmtWindowUpdate.frame)
    for frmTyp in allFrames-{frmtRstStream,frmtPriority,frmtWindowUpdate}:
      doAssert(not isAllowedToRecv(strmReservedLocal, frmTyp.frame))
    doAssert isAllowedToRecv(strmReservedRemote, frmtHeaders.frame)
    doAssert isAllowedToRecv(strmReservedRemote, frmtRstStream.frame)
    doAssert isAllowedToRecv(strmReservedRemote, frmtPriority.frame)
    for frmTyp in allFrames-{frmtHeaders,frmtRstStream,frmtPriority}:
      doAssert(not isAllowedToRecv(strmReservedRemote, frmTyp.frame))
    for frmTyp in allFrames:
      doAssert isAllowedToRecv(strmOpen, frmTyp.frame)
    for frmTyp in allFrames:
      doAssert isAllowedToRecv(strmHalfClosedLocal, frmTyp.frame)
    doAssert isAllowedToRecv(strmHalfClosedRemote, frmtWindowUpdate.frame)
    doAssert isAllowedToRecv(strmHalfClosedRemote, frmtPriority.frame)
    doAssert isAllowedToRecv(strmHalfClosedRemote, frmtRstStream.frame)
    for frmTyp in allFrames-{frmtWindowUpdate,frmtPriority,frmtRstStream}:
      doAssert(not isAllowedToRecv(strmHalfClosedRemote, frmTyp.frame))
    for frmTyp in allFrames:
      doAssert isAllowedToRecv(strmClosed, frmTyp.frame)
    for frmTyp in allFrames:
      doAssert(not isAllowedToRecv(strmInvalid, frmTyp.frame))

  echo "ok"