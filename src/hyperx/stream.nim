import std/tables

import ./frame
import ./queue
import ./signal
import ./errors

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
    seHeadersEndStream
    sePushPromise
    seRstStream
    sePriority
    seWindowUpdate
    seData
    seDataEndStream
    seUnknown

const streamEvents* = {
  seHeaders,
  seHeadersEndStream,
  sePushPromise,
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
  # clients are not allowed to send push promise
  # only servers
  frmtPushPromise,
  frmtWindowUpdate
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
  of frmtPushPromise:
    sePushPromise
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
    of sePushPromise: strmReservedRemote
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
    of seHeadersEndStream,
      seDataEndStream,
      seRstStream: strmClosed
    else: strmHalfClosedLocal
  of strmHalfClosedRemote, strmReservedLocal:
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
    of sePushPromise: strmReservedLocal
    of seHeadersEndStream: strmHalfClosedLocal
    of sePriority: strmIdle
    else: strmInvalid
  of strmOpen:
    case e
    of seHeadersEndStream,
      seDataEndStream: strmHalfClosedLocal
    of seRstStream: strmClosed
    else: strmOpen
  of strmClosed:
    #case e
    #of sePriority,
    #  seRstStream: strmClosed
    #else: strmInvalid
    # if peer closes the conn they still need
    # to process anything we send
    strmClosed
  of strmReservedLocal:
    case e
    of seHeaders: strmHalfClosedRemote
    of seRstStream: strmClosed
    of sePriority: strmReservedLocal
    else: strmInvalid
  of strmHalfClosedRemote:
    case e
    of seHeadersEndStream,
      seDataEndStream,
      seRstStream: strmClosed
    else: strmHalfClosedRemote
  of strmHalfClosedLocal, strmReservedRemote:
    case e
    of seRstStream: strmClosed
    of seWindowUpdate, sePriority: s
    else: strmInvalid
  of strmInvalid:
    doAssert false
    strmInvalid

type
  StreamId* = distinct uint32  # range[0 .. 31.ones.int]

proc `==`*(a, b: StreamId): bool {.borrow.}
proc `+=`*(a: var StreamId, b: StreamId) {.borrow.}
proc `<`*(a, b: StreamId): bool {.borrow.}

type
  Stream* = ref object
    id*: StreamId
    state*: StreamState
    msgs*: QueueAsync[Frame]
    peerWindow*: int32
    peerWindowUpdateSig*: SignalAsync
    window*: int
    error*: ref StrmError

proc newStream(id: StreamId, peerWindow: int32): Stream {.raises: [].} =
  doAssert peerWindow >= 0
  Stream(
    id: id,
    state: strmIdle,
    msgs: newQueue[Frame](1),
    peerWindow: peerWindow,
    peerWindowUpdateSig: newSignal(),
    window: 0
  )

proc close*(stream: Stream) {.raises: [].} =
  stream.state = strmClosed
  stream.msgs.close()
  stream.peerWindowUpdateSig.close()

func errCodeOrDefault*(stream: Stream, default: ErrorCode): ErrorCode =
  if stream.error != nil:
    return stream.error.code
  return default

type
  StreamsClosedError* = object of HyperxError
  Streams* = object
    t: Table[StreamId, Stream]
    isClosed: bool

func initStreams*(): Streams {.raises: [].} =
  result = Streams(
    t: initTable[StreamId, Stream](16),
    isClosed: false
  )

func len*(s: Streams): int {.inline, raises: [].} =
  result = s.t.len

func get*(s: var Streams, sid: StreamId): var Stream {.raises: [].} =
  try:
    result = s.t[sid]
  except KeyError:
    doAssert false, "sid is not a stream"

func del*(s: var Streams, sid: StreamId) {.raises: [].} =
  s.t.del sid

func contains*(s: Streams, sid: StreamId): bool {.raises: [].} =
  s.t.contains sid

func open*(
  s: var Streams,
  sid: StreamId,
  peerWindow: int32
): Stream {.raises: [StreamsClosedError].} =
  doAssert sid notin s.t, $sid.int
  if s.isClosed:
    raise newException(StreamsClosedError, "Streams is closed")
  result = newStream(sid, peerWindow)
  s.t[sid] = result

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
    sePushPromise,
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
    doAssert toNextStateRecv(strmIdle, seHeadersEndStream) == strmHalfClosedRemote
    doAssert toNextStateRecv(strmIdle, sePriority) == strmIdle
    for ev in streamEvents-{seHeaders, sePushPromise, seHeadersEndStream, sePriority}:
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
    doAssert toNextStateRecv(strmClosed, sePushPromise) == strmReservedRemote
    for ev in streamEvents-{sePriority,seWindowUpdate,seRstStream,sePushPromise}:
      doAssert toNextStateRecv(strmClosed, ev) == strmInvalid
    doAssert toNextStateRecv(strmReservedRemote, seHeaders) == strmHalfClosedLocal
    doAssert toNextStateRecv(strmReservedRemote, seRstStream) == strmClosed
    doAssert toNextStateRecv(strmReservedRemote, sePriority) == strmReservedRemote
    for ev in streamEvents-{seHeaders,seRstStream,sePriority}:
      doAssert toNextStateRecv(strmReservedRemote, ev) == strmInvalid
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
    doAssert toStreamEvent(frmtData.frame(frmfEndStream.FrmFlags)) == seDataEndStream
    doAssert toStreamEvent(frmtHeaders.frame) == seHeaders
    doAssert toStreamEvent(frmtHeaders.frame(frmfEndStream.FrmFlags)) == seHeadersEndStream
    doAssert toStreamEvent(frmtPriority.frame) == sePriority
    doAssert toStreamEvent(frmtRstStream.frame) == seRstStream
    doAssert toStreamEvent(frmtPushPromise.frame) == sePushPromise
    doAssert toStreamEvent(frmtWindowUpdate.frame) == seWindowUpdate

  echo "ok"