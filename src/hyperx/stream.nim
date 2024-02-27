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
    seHeaders
    sePushPromise
    seEndStream
    seRstStream
    sePriority
    seWindowUpdate
    seData
    seUnknown

const streamEvents* = {
  seHeaders,
  sePushPromise,
  seEndStream,
  seRstStream,
  sePriority,
  seWindowUpdate,
  seData
}

const frmStreamAllowed* = {
  frmtData,
  frmtHeaders,
  frmtPriority,
  frmtRstStream,
  # clients are not allowed to send push promise
  # only servers
  frmtPushPromise,
  frmtWindowUpdate
}

func toStreamEvent*(frm: Frame): StreamEvent {.raises: [].} =
  case frm.typ
  of frmtData:
    if frmfEndStream in frm.flags:
      seEndStream
    else:
      seData
  of frmtHeaders:
    if frmfEndStream in frm.flags:
      seEndStream
    else:
      seHeaders
  of frmtPriority:
    sePriority
  of frmtRstStream:
    seRstStream
  of frmtPushPromise:
    sePushPromise
  of frmtWindowUpdate:
    seWindowUpdate
  else:
    doAssert false
    seUnknown

func isAllowedToRecv*(state: StreamState, frm: Frame): bool {.raises: [].} =
  ## Check if the stream is allowed to receive the frame
  # https://httpwg.org/specs/rfc9113.html#StreamStates
  case state
  of strmIdle:
    frm.typ in {frmtHeaders, frmtPriority}
  of strmHalfClosedRemote, strmReservedLocal:
    # XXX need to respond with stream closed error (strmHalfClosedRemote)
    frm.typ in {frmtRstStream, frmtPriority, frmtWindowUpdate}
  of strmReservedRemote:
    frm.typ in {frmtHeaders, frmtRstStream, frmtPriority}
  of strmOpen, strmHalfClosedLocal:
    true
  of strmClosed:  # XXX only do minimal processing of frames
    true
  of strmInvalid: false

# Section 5.1
func toNextStateRecv*(s: StreamState, e: StreamEvent): StreamState {.raises: [].} =
  doAssert e != seUnknown
  case s
  of strmIdle:
    case e:
    of seHeaders: strmOpen
    of sePushPromise: strmReservedRemote
    of seEndStream: strmHalfClosedRemote
    of sePriority: strmIdle
    else: strmInvalid
  of strmOpen:
    case e
    of seEndStream: strmHalfClosedRemote
    of seRstStream: strmClosed
    else: strmOpen
  of strmClosed:
    case e
    of sePriority,
      seWindowUpdate,
      seRstStream: strmClosed
    of sePushPromise: strmReservedRemote
    else: strmInvalid
  of strmReservedRemote:
    case e
    of seHeaders: strmHalfClosedLocal
    of seRstStream: strmClosed
    of sePriority: strmReservedRemote
    else: strmInvalid
  of strmHalfClosedLocal:
    case e
    of seEndStream, seRstStream: strmClosed
    else: strmHalfClosedLocal
  of strmHalfClosedRemote, strmReservedLocal:
    case e
    of seRstStream: strmClosed
    of seWindowUpdate, sePriority: s
    else: strmInvalid
  of strmInvalid:
    doAssert false
    strmInvalid

func isAllowedToSend*(state: StreamState, frm: Frame): bool {.raises: [].} =
  ## Check if the stream is allowed to send the frame
  case state
  of strmIdle:
    frm.typ in {frmtHeaders, frmtPriority}
  of strmReservedLocal:
    frm.typ in {frmtHeaders, frmtRstStream, frmtPriority}
  of strmReservedRemote, strmHalfClosedLocal:
    frm.typ in {frmtRstStream, frmtWindowUpdate, frmtPriority}
  of strmOpen, strmHalfClosedRemote:
    true
  of strmClosed:
    frm.typ in {frmtPriority}
  of strmInvalid: false

# Section 5.1
func toNextStateSend*(s: StreamState, e: StreamEvent): StreamState {.raises: [].} =
  doAssert e != seUnknown
  case s
  of strmIdle:
    case e:
    of seHeaders: strmOpen
    of sePushPromise: strmReservedLocal
    of seEndStream: strmHalfClosedLocal
    of sePriority: strmIdle
    else: strmInvalid
  of strmOpen:
    case e
    of seEndStream: strmHalfClosedLocal
    of seRstStream: strmClosed
    else: strmOpen
  of strmClosed:
    case e
    of sePriority: strmClosed
    else: strmInvalid
  of strmReservedLocal:
    case e
    of seHeaders: strmHalfClosedRemote
    of seRstStream: strmClosed
    of sePriority: strmReservedLocal
    else: strmInvalid
  of strmHalfClosedRemote:
    case e
    of seEndStream, seRstStream: strmClosed
    else: strmHalfClosedRemote
  of strmHalfClosedLocal, strmReservedRemote:
    case e
    of seRstStream: strmClosed
    of seWindowUpdate, sePriority: s
    else: strmInvalid
  of strmInvalid:
    doAssert false
    strmInvalid

when isMainModule:
  import ./utils
  func frame(typ: FrmTyp, flags = 0.FrmFlags): Frame =
    result = newFrame()
    result.setTyp typ
    result.setFlags flags
  const allEvents = {
    seHeaders,
    sePushPromise,
    seEndStream,
    seRstStream,
    sePriority,
    seWindowUpdate,
    seData,
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
    for ev in allEvents-streamEvents:
      raisesAssertion:
        discard toNextStateRecv(strmIdle, ev)
    raisesAssertion:
      discard toNextStateRecv(strmIdle, seUnknown)
  block:
    doAssert toNextStateRecv(strmIdle, seHeaders) == strmOpen
    doAssert toNextStateRecv(strmIdle, sePushPromise) == strmReservedRemote
    doAssert toNextStateRecv(strmIdle, seEndStream) == strmHalfClosedRemote
    doAssert toNextStateRecv(strmIdle, sePriority) == strmIdle
    for ev in streamEvents-{seHeaders, sePushPromise, seEndStream, sePriority}:
      doAssert toNextStateRecv(strmIdle, ev) == strmInvalid
    doAssert toNextStateRecv(strmOpen, seEndStream) == strmHalfClosedRemote
    doAssert toNextStateRecv(strmOpen, seRstStream) == strmClosed
    doAssert toNextStateRecv(strmOpen, seData) == strmOpen
    for ev in streamEvents-{seEndStream, seRstStream}:
      doAssert toNextStateRecv(strmOpen, ev) == strmOpen
    doAssert toNextStateRecv(strmClosed, sePriority) == strmClosed
    doAssert toNextStateRecv(strmClosed, seWindowUpdate) == strmClosed
    doAssert toNextStateRecv(strmClosed, seRstStream) == strmClosed
    doAssert toNextStateRecv(strmClosed, sePushPromise) == strmReservedRemote
    for ev in streamEvents-{sePriority,seWindowUpdate,seRstStream,sePushPromise}:
      doAssert toNextStateRecv(strmClosed, ev) == strmInvalid
    doAssert toNextStateRecv(strmReservedRemote, seHeaders) == strmHalfClosedLocal
    doAssert toNextStateRecv(strmReservedRemote, seRstStream) == strmClosed
    doAssert toNextStateRecv(strmReservedRemote, sePriority) == strmReservedRemote
    for ev in streamEvents-{seHeaders,seRstStream,sePriority}:
      doAssert toNextStateRecv(strmReservedRemote, ev) == strmInvalid
    doAssert toNextStateRecv(strmHalfClosedLocal, seEndStream) == strmClosed
    doAssert toNextStateRecv(strmHalfClosedLocal, seRstStream) == strmClosed
    doAssert toNextStateRecv(strmHalfClosedLocal, seData) == strmHalfClosedLocal
    for ev in streamEvents-{seEndStream,seRstStream}:
      doAssert toNextStateRecv(strmHalfClosedLocal, ev) == strmHalfClosedLocal
    doAssert toNextStateRecv(strmHalfClosedRemote, seRstStream) == strmClosed
    doAssert toNextStateRecv(strmHalfClosedRemote, seWindowUpdate) == strmHalfClosedRemote
    doAssert toNextStateRecv(strmHalfClosedRemote, sePriority) == strmHalfClosedRemote
    for ev in streamEvents-{seRstStream,seWindowUpdate,sePriority}:
      doAssert toNextStateRecv(strmHalfClosedRemote, ev) == strmInvalid
    doAssert toNextStateRecv(strmReservedLocal, seRstStream) == strmClosed
    doAssert toNextStateRecv(strmReservedLocal, seWindowUpdate) == strmReservedLocal
    doAssert toNextStateRecv(strmReservedLocal, sePriority) == strmReservedLocal
    for ev in streamEvents-{seRstStream,seWindowUpdate,sePriority}:
      doAssert toNextStateRecv(strmReservedLocal, ev) == strmInvalid
    for ev in streamEvents:
      raisesAssertion:
        discard toNextStateRecv(strmInvalid, ev)
  block:
    for frmTyp in allFrames-frmStreamAllowed:
      raisesAssertion:
        discard toStreamEvent(frmTyp.frame)
    doAssert toStreamEvent(frmtData.frame) == seData
    doAssert toStreamEvent(frmtData.frame(frmfEndStream.FrmFlags)) == seEndStream
    doAssert toStreamEvent(frmtHeaders.frame) == seHeaders
    doAssert toStreamEvent(frmtHeaders.frame(frmfEndStream.FrmFlags)) == seEndStream
    doAssert toStreamEvent(frmtPriority.frame) == sePriority
    doAssert toStreamEvent(frmtRstStream.frame) == seRstStream
    doAssert toStreamEvent(frmtPushPromise.frame) == sePushPromise
    doAssert toStreamEvent(frmtWindowUpdate.frame) == seWindowUpdate
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