import std/asyncdispatch
import std/deques

import ./utils
import ./errors

type
  SignalClosedError* = QueueClosedError

func newSignalClosedError(): ref SignalClosedError {.raises: [].} =
  result = (ref SignalClosedError)(msg: "Signal is closed")

type
  SignalAsync* = ref object
    ## Wait for a signal. When triggers wakes everyone up
    # XXX use/reuse FutureVars
    sigEv: Deque[Future[void]]
    isClosed: bool

proc newSignal*(): SignalAsync {.raises: [].} =
  new result
  result = SignalAsync(
    sigEv: initDeque[Future[void]](0),
    isClosed: false
  )

proc sigEvent(sig: SignalAsync): Future[void] {.raises: [].} =
  result = newFuture[void]()
  sig.sigEv.addFirst result

# XXX switch to wakeupNext like queue/lock
#     otherwise we don't know async will
#     run the futures in FIFO order

proc sigDone(sig: SignalAsync) {.raises: [].} =
  untrackExceptions:
    while sig.sigEv.len > 0:
      sig.sigEv.popLast().complete()

proc waitFor*(sig: SignalAsync): Future[void] {.async.} =
  if sig.isClosed:
    raise newSignalClosedError()
  await sig.sigEvent()

proc trigger*(sig: SignalAsync) {.raises: [SignalClosedError].} =
  if sig.isClosed:
    raise newSignalClosedError()
  sig.sigDone()

func isClosed*(sig: SignalAsync): bool {.raises: [].} =
  sig.isClosed

proc close*(sig: SignalAsync) {.raises: [].}  =
  if sig.isClosed:
    return
  sig.isClosed = true
  untrackExceptions:
    while sig.sigEv.len > 0:
      sig.sigEv.popLast().fail newSignalClosedError()

when isMainModule:
  block:
    proc test() {.async.} =
      var sig = newSignal()
      var puts = newSeq[int]()
      proc putOne(i: int) {.async.} =
        doAssert puts.len == 0
        await sig.waitFor()
        puts.add i
      proc atrigger(sig: SignalAsync) {.async.} =
        doAssert puts.len == 0
        sig.trigger()
        doAssert puts.len == 6
      await (
        putOne(1) and
        putOne(2) and
        putOne(3) and
        putOne(4) and
        putOne(5) and
        putOne(6) and
        sig.atrigger()
      )
      doAssert puts == @[1,2,3,4,5,6]
    waitFor test()
  echo "ok"
