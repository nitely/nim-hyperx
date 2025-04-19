import std/tables

import ./frame
import ./signal
import ./errors
import ./utils

# Section 5.1
type
  StreamState* = enum
    strmIdle
    strmOpen
    strmClosed
    strmHalfClosedLocal
    strmHalfClosedRemote
    strmClosedRst
    strmInvalid
  StreamEvent* = enum
    seHeaders
    seHeadersEndStream
    seRstStream
    sePriority
    seWindowUpdate
    seData
    seDataEndStream
    seUnknown

const streamEvents* = {
  seHeaders,
  seHeadersEndStream,
  seRstStream,
  sePriority,
  seWindowUpdate,
  seData,
  seDataEndStream
}

const frmStreamAllowed* = {
  frmtData,
  frmtHeaders,
  frmtPriority,
  frmtRstStream,
  frmtWindowUpdate
}

const strmStateHeaderSendAllowed* = {
  strmIdle,
  strmOpen,
  strmHalfClosedRemote
}

const strmStateDataSendAllowed* = {
  strmOpen,
  strmHalfClosedRemote
}

const strmStateRstSendAllowed* = {
  strmOpen,
  strmHalfClosedRemote,
  strmHalfClosedLocal
}

const strmStateWindowSendAllowed* = {
  strmOpen,
  strmHalfClosedRemote,
  strmHalfClosedLocal
}

func toStreamEvent*(frm: Frame): StreamEvent {.raises: [].} =
  case frm.typ
  of frmtData:
    if frmfEndStream in frm.flags:
      seDataEndStream
    else:
      seData
  of frmtHeaders:
    if frmfEndStream in frm.flags:
      seHeadersEndStream
    else:
      seHeaders
  of frmtPriority:
    sePriority
  of frmtRstStream:
    seRstStream
  of frmtWindowUpdate:
    seWindowUpdate
  else:
    doAssert false
    seUnknown

func toNextStateRecv*(s: StreamState, e: StreamEvent): StreamState {.raises: [].} =
  # https://httpwg.org/specs/rfc9113.html#StreamStates
  doAssert e != seUnknown
  case s
  of strmIdle:
    case e:
    of seHeaders: strmOpen
    of seHeadersEndStream: strmHalfClosedRemote
    of sePriority: strmIdle
    else: strmInvalid
  of strmOpen:
    case e
    of seHeadersEndStream,
      seDataEndStream: strmHalfClosedRemote
    of seRstStream: strmClosed
    else: strmOpen
  of strmClosed:
    case e
    of sePriority,
      seWindowUpdate,
      seRstStream: strmClosed
    else: strmInvalid
  of strmHalfClosedLocal, strmClosedRst:
    case e
    of seHeadersEndStream,
      seDataEndStream,
      seRstStream: strmClosed
    else: s
  of strmHalfClosedRemote:
    case e
    of seRstStream: strmClosed
    of seWindowUpdate, sePriority: s
    else: strmInvalid
  of strmInvalid:
    doAssert false
    strmInvalid

func toNextStateSend*(s: StreamState, e: StreamEvent): StreamState {.raises: [].} =
  # https://httpwg.org/specs/rfc9113.html#StreamStates
  doAssert e != seUnknown
  case s
  of strmIdle:
    case e:
    of seHeaders: strmOpen
    of seHeadersEndStream: strmHalfClosedLocal
    of sePriority: strmIdle
    else: strmInvalid
  of strmOpen:
    case e
    of seHeadersEndStream,
      seDataEndStream: strmHalfClosedLocal
    of seRstStream: strmClosedRst
    else: strmOpen
  of strmClosed, strmClosedRst:
    case e
    of sePriority: s
    else: strmInvalid
  of strmHalfClosedRemote:
    case e
    of seHeadersEndStream,
      seDataEndStream,
      seRstStream: strmClosed
    else: strmHalfClosedRemote
  of strmHalfClosedLocal:
    case e
    of seRstStream: strmClosedRst
    of seWindowUpdate, sePriority: s
    else: strmInvalid
  of strmInvalid:
    doAssert false
    strmInvalid

type
  StreamCtxState* = enum
    csStateHeaders,
    csStateData,
    csStateEnded
  StreamId* = FrmSid
  Stream* = ref object
    id*: StreamId
    state*: StreamState
    peerWindow*: int32
    peerWindowUpdateSig*: SignalAsync
    windowPending*: int
    windowProcessed*: int
    pingSig*: SignalAsync
    stateRecv*, stateSend*: StreamCtxState
    contentLen*, contentLenRecv*: int64
    headersRecv*, bodyRecv*, trailersRecv*: string
    headersRecvSig*, bodyRecvSig*: SignalAsync
    bodyRecvLen*: int
    error*: ref HyperxStrmError
    onClose: proc () {.closure, gcsafe, raises: [].}

proc newStream(id: StreamId, peerWindow: int32): Stream {.raises: [].} =
  doAssert peerWindow >= 0
  Stream(
    id: id,
    state: strmIdle,
    peerWindow: peerWindow,
    peerWindowUpdateSig: newSignal(),
    windowPending: 0,
    windowProcessed: 0,
    pingSig: newSignal(),
    stateRecv: csStateHeaders,
    stateSend: csStateHeaders,
    contentLen: 0,
    contentLenRecv: 0,
    bodyRecv: "",
    bodyRecvSig: newSignal(),
    bodyRecvLen: 0,
    headersRecv: "",
    headersRecvSig: newSignal(),
    trailersRecv: ""
  )

proc close*(stream: Stream) {.raises: [].} =
  stream.state = strmClosed
  stream.peerWindowUpdateSig.close()
  stream.pingSig.close()
  stream.bodyRecvSig.close()
  stream.headersRecvSig.close()
  if stream.onClose != nil:
    stream.onClose()

func onClose*(stream: Stream, cb: proc () {.closure, gcsafe, raises: [].}) =
  doAssert stream.onClose == nil
  stream.onClose = cb

type StreamsClosedError* = object of QueueClosedError

func newStreamsClosedError*(msg: string): ref StreamsClosedError {.raises: [].} =
  result = (ref StreamsClosedError)(msg: msg)

type
  Streams* = object
    t: Table[StreamId, Stream]
    isClosed: bool

func initStreams*(): Streams {.raises: [].} =
  result = Streams(
    t: initTable[StreamId, Stream](16),
    isClosed: false
  )

func len*(s: Streams): int {.raises: [].} =
  result = s.t.len

func get*(s: var Streams, sid: StreamId): Stream {.raises: [].} =
  result = default(Stream)
  try:
    result = s.t[sid]
  except KeyError:
    doAssert false

func del*(s: var Streams, sid: StreamId) {.raises: [].} =
  s.t.del sid

func contains*(s: Streams, sid: StreamId): bool {.raises: [].} =
  s.t.contains sid

func dummy*(s: var Streams): Stream {.raises: [StreamsClosedError].} =
  check not s.isClosed, newStreamsClosedError("Cannot open stream")
  result = newStream(uint32.high.StreamId, 0)

func open*(
  s: var Streams,
  stream: Stream,
  sid: StreamId,
  peerWindow: int32
) {.raises: [StreamsClosedError].} =
  doAssert sid notin s.t, $sid.int
  doAssert stream.id == uint32.high.StreamId
  doAssert stream.state == strmIdle
  check not s.isClosed, newStreamsClosedError("Cannot open stream")
  stream.id = sid
  stream.peerWindow = peerWindow
  s.t[sid] = stream

func open*(
  s: var Streams,
  sid: StreamId,
  peerWindow: int32
): Stream {.raises: [StreamsClosedError].} =
  result = s.dummy()
  s.open(result, sid, peerWindow)

iterator values*(s: Streams): Stream {.inline.} =
  for v in values s.t:
    yield v

proc close*(s: var Streams, sid: StreamId) {.raises: [].} =
  if sid notin s:
    return
  let stream = s.get sid
  stream.close()
  s.del sid

proc close*(s: var Streams) {.raises: [].} =
  if s.isClosed:
    return
  s.isClosed = true
  for stream in values s:
    stream.close()

when isMainModule:
  import ./utils
  func frame(typ: FrmTyp, flags = 0.FrmFlags): Frame =
    result = newFrame()
    result.setTyp typ
    result.setFlags flags
  const allEvents = {
    seHeaders,
    seHeadersEndStream,
    seRstStream,
    sePriority,
    seWindowUpdate,
    seData,
    seDataEndStream,
    seUnknown
  }
  const allFrames = {
    frmtData,
    frmtHeaders,
    frmtPriority,
    frmtRstStream,
    frmtSettings,
    frmtPing,
    frmtGoAway,
    frmtWindowUpdate,
    frmtContinuation,
  }
  const allStates = {
    strmIdle,
    strmOpen,
    strmClosed,
    strmHalfClosedLocal,
    strmHalfClosedRemote,
    strmClosedRst
    #strmInvalid
  }
  block:
    for ev in allEvents-streamEvents:
      raisesAssertion:
        discard toNextStateRecv(strmIdle, ev)
    raisesAssertion:
      discard toNextStateRecv(strmIdle, seUnknown)
  block:
    doAssert toNextStateRecv(strmIdle, seHeaders) == strmOpen
    doAssert toNextStateRecv(strmIdle, seHeadersEndStream) == strmHalfClosedRemote
    doAssert toNextStateRecv(strmIdle, sePriority) == strmIdle
    for ev in streamEvents-{seHeaders, seHeadersEndStream, sePriority}:
      doAssert toNextStateRecv(strmIdle, ev) == strmInvalid
    doAssert toNextStateRecv(strmOpen, seHeadersEndStream) == strmHalfClosedRemote
    doAssert toNextStateRecv(strmOpen, seDataEndStream) == strmHalfClosedRemote
    doAssert toNextStateRecv(strmOpen, seRstStream) == strmClosed
    doAssert toNextStateRecv(strmOpen, seData) == strmOpen
    for ev in streamEvents-{seHeadersEndStream, seDataEndStream, seRstStream}:
      doAssert toNextStateRecv(strmOpen, ev) == strmOpen
    doAssert toNextStateRecv(strmClosed, sePriority) == strmClosed
    doAssert toNextStateRecv(strmClosed, seWindowUpdate) == strmClosed
    doAssert toNextStateRecv(strmClosed, seRstStream) == strmClosed
    for ev in streamEvents-{sePriority,seWindowUpdate,seRstStream}:
      doAssert toNextStateRecv(strmClosed, ev) == strmInvalid
    doAssert toNextStateRecv(strmHalfClosedLocal, seHeadersEndStream) == strmClosed
    doAssert toNextStateRecv(strmHalfClosedLocal, seDataEndStream) == strmClosed
    doAssert toNextStateRecv(strmHalfClosedLocal, seRstStream) == strmClosed
    doAssert toNextStateRecv(strmHalfClosedLocal, seData) == strmHalfClosedLocal
    for ev in streamEvents-{seHeadersEndStream,seDataEndStream,seRstStream}:
      doAssert toNextStateRecv(strmHalfClosedLocal, ev) == strmHalfClosedLocal
    doAssert toNextStateRecv(strmHalfClosedRemote, seRstStream) == strmClosed
    doAssert toNextStateRecv(strmHalfClosedRemote, seWindowUpdate) == strmHalfClosedRemote
    doAssert toNextStateRecv(strmHalfClosedRemote, sePriority) == strmHalfClosedRemote
    for ev in streamEvents-{seRstStream,seWindowUpdate,sePriority}:
      doAssert toNextStateRecv(strmHalfClosedRemote, ev) == strmInvalid
    for ev in streamEvents:
      raisesAssertion:
        discard toNextStateRecv(strmInvalid, ev)
  block:
    for frmTyp in allFrames-frmStreamAllowed:
      raisesAssertion:
        discard toStreamEvent(frmTyp.frame)
    doAssert toStreamEvent(frmtData.frame) == seData
    doAssert toStreamEvent(frmtData.frame(frmfEndStream.FrmFlags)) == seDataEndStream
    doAssert toStreamEvent(frmtHeaders.frame) == seHeaders
    doAssert toStreamEvent(frmtHeaders.frame(frmfEndStream.FrmFlags)) == seHeadersEndStream
    doAssert toStreamEvent(frmtPriority.frame) == sePriority
    doAssert toStreamEvent(frmtRstStream.frame) == seRstStream
    doAssert toStreamEvent(frmtWindowUpdate.frame) == seWindowUpdate
  block:
    for ev in {seHeaders, seHeadersEndStream}:
      for state in allStates:
        let isValid = toNextStateSend(state, ev) != strmInvalid
        doAssert state in strmStateHeaderSendAllowed == isValid, $state & " " & $ev
  block:
    for ev in {seData, seDataEndStream}:
      for state in allStates:
        let isValid = toNextStateSend(state, ev) != strmInvalid
        doAssert state in strmStateDataSendAllowed == isValid, $state & " " & $ev
  block:
    for state in allStates:
      let isValid = toNextStateSend(state, seRstStream) != strmInvalid
      doAssert state in strmStateRstSendAllowed == isValid, $state
  block:
    for state in allStates:
      let isValid = toNextStateSend(state, seWindowUpdate) != strmInvalid
      doAssert state in strmStateWindowSendAllowed == isValid, $state
  block send_headers_and_headers_end:
    for state in allStates:
      let isValid = toNextStateSend(state, seHeaders) != strmInvalid
      let isValid2 = toNextStateSend(state, seHeadersEndStream) != strmInvalid
      doAssert isValid == isValid2, $state
  block send_data_and_data_end:
    for state in allStates:
      let isValid = toNextStateSend(state, seData) != strmInvalid
      let isValid2 = toNextStateSend(state, seDataEndStream) != strmInvalid
      doAssert isValid == isValid2, $state
  block recv_headers_and_headers_end:
    for state in allStates:
      let isValid = toNextStateRecv(state, seHeaders) != strmInvalid
      let isValid2 = toNextStateRecv(state, seHeadersEndStream) != strmInvalid
      doAssert isValid == isValid2, $state
  block recv_data_and_data_end:
    for state in allStates:
      let isValid = toNextStateRecv(state, seData) != strmInvalid
      let isValid2 = toNextStateRecv(state, seDataEndStream) != strmInvalid
      doAssert isValid == isValid2, $state
  block:
    for ev in allEvents-{seUnknown,sePriority}:
      doAssert toNextStateSend(strmClosedRst, ev) == strmInvalid
    doAssert toNextStateSend(strmClosedRst, sePriority) == strmClosedRst
  block:
    for state in {strmOpen,strmHalfClosedLocal}:
      doAssert toNextStateSend(state, seRstStream) == strmClosedRst
    for state in allStates-{strmOpen,strmHalfClosedLocal}:
      doAssert toNextStateSend(state, seRstStream) in {strmInvalid, strmClosed}
  block:
    for ev in allEvents-{seUnknown,seRstStream,seHeadersEndStream,seDataEndStream}:
      doAssert toNextStateRecv(strmClosedRst, ev) == strmClosedRst
      doAssert toNextStateRecv(strmHalfClosedLocal, ev) == strmHalfClosedLocal
    for ev in {seRstStream,seHeadersEndStream,seDataEndStream}:
      doAssert toNextStateRecv(strmClosedRst, ev) == strmClosed
      doAssert toNextStateRecv(strmHalfClosedLocal, ev) == strmClosed

  echo "ok"