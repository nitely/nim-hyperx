import std/tables

import ./frame
import ./queue
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

func toNextStateRecv*(s: StreamState, e: StreamEvent): StreamState {.raises: [].} =
  # https://httpwg.org/specs/rfc9113.html#StreamStates
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

func toNextStateSend*(s: StreamState, e: StreamEvent): StreamState {.raises: [].} =
  # https://httpwg.org/specs/rfc9113.html#StreamStates
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

type
  StreamId* = distinct uint32  # range[0 .. 31.ones.int]

proc `==`*(a, b: StreamId): bool {.borrow.}
proc `+=`*(a: var StreamId, b: StreamId) {.borrow.}
proc `<`*(a, b: StreamId): bool {.borrow.}

type
  Stream* = object
    id*: StreamId
    state*: StreamState
    msgs*: QueueAsync[Frame]

proc initStream(id: StreamId): Stream {.raises: [].} =
  result = Stream(
    id: id,
    state: strmIdle,
    msgs: newQueue[Frame](1)
  )

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

func get*(s: var Streams, sid: StreamId): var Stream {.raises: [].} =
  try:
    result = s.t[sid]
  except KeyError:
    doAssert false, "sid is not a stream"

func del*(s: var Streams, sid: StreamId) {.raises: [].} =
  s.t.del sid

func contains*(s: Streams, sid: StreamId): bool {.raises: [].} =
  s.t.contains sid

func open*(s: var Streams, sid: StreamId) {.raises: [StreamsClosedError].} =
  doAssert sid notin s.t, $sid.int
  if s.isClosed:
    raise newException(StreamsClosedError, "Streams is closed")
  s.t[sid] = initStream(sid)

iterator values*(s: Streams): Stream {.inline.} =
  for v in values s.t:
    yield v

proc close*(s: var Streams, sid: StreamId) {.raises: [].} =
  if sid notin s:
    return
  let stream = s.get sid
  stream.msgs.close()
  s.del sid

proc close*(s: var Streams) {.raises: [].} =
  if s.isClosed:
    return
  s.isClosed = true
  for stream in values s:
    stream.msgs.close()

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

  echo "ok"