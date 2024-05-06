import yasync
from std/asyncdispatch import callSoon
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
    waiters: Deque[Future[void]]
    wakingUp: bool
    isClosed: bool

proc newSignal*(): SignalAsync {.raises: [].} =
  new result
  result = SignalAsync(
    waiters: initDeque[Future[void]](0),
    wakingUp: false,
    isClosed: false
  )

proc wakeupLastWaiter(sig: SignalAsync) {.raises: [].} =
  if sig.waiters.len == 0:
    return
  if sig.wakingUp:
    return
  proc wakeup =
    sig.wakingUp = false
    if sig.waiters.len > 0:
      let fut = sig.waiters.peekLast()
      if not fut.finished:
        fut.complete()
  untrackExceptions:
    sig.wakingUp = true
    callSoon wakeup

proc waitFor*(sig: SignalAsync) {.async.} =
  if sig.isClosed:
    raise newSignalClosedError()
  let fut = newFuture(void)
  sig.waiters.addFirst fut
  await fut
  if sig.isClosed:
    raise newSignalClosedError()
  let fut2 = sig.waiters.popLast()
  doAssert fut == fut2
  sig.wakeupLastWaiter()

proc trigger*(sig: SignalAsync) {.raises: [SignalClosedError].} =
  if sig.isClosed:
    raise newSignalClosedError()
  sig.wakeupLastWaiter()

func isClosed*(sig: SignalAsync): bool {.raises: [].} =
  sig.isClosed

proc close*(sig: SignalAsync) {.raises: [].}  =
  if sig.isClosed:
    return
  sig.isClosed = true
  proc failWaiters =
    while sig.waiters.len > 0:
      let fut = sig.waiters.popLast()
      if not fut.finished:
        fut.fail newSignalClosedError()
  untrackExceptions:
    callSoon failWaiters

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
        doAssert puts.len == 0
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
