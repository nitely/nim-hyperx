import std/asyncdispatch

import ./utils
import ./errors

type
  SignalClosedError* = QueueClosedError

func newSignalClosedError(): ref SignalClosedError {.raises: [].} =
  result = (ref SignalClosedError)(msg: "Signal is closed")

type
  SignalAsync* = ref object
    ## Wait for a signal. When triggers wakes everyone up
    waiters: seq[Future[void]]
    isClosed: bool

proc newSignal*(): SignalAsync {.raises: [].} =
  new result
  result = SignalAsync(
    waiters: newSeq[Future[void]](),
    isClosed: false
  )

proc len*(sig: SignalAsync): int {.raises: [].} =
  sig.waiters.len

proc waitFor*(sig: SignalAsync): Future[void] {.raises: [SignalClosedError].} =
  if sig.isClosed:
    raise newSignalClosedError()
  result = newFuture[void]()
  sig.waiters.add result

proc wakeupSoon(f: Future[void]) {.raises: [].} =
  if not f.finished:
    uncatch f.complete()

proc trigger*(sig: SignalAsync) {.raises: [SignalClosedError].} =
  if sig.isClosed:
    raise newSignalClosedError()
  for fut in sig.waiters:
    wakeupSoon fut
  sig.waiters.setLen 0

func isClosed*(sig: SignalAsync): bool {.raises: [].} =
  sig.isClosed

proc failSoon(f: Future[void]) {.raises: [].} =
  if not f.finished:
    uncatch f.fail newSignalClosedError()

proc close*(sig: SignalAsync) {.raises: [].}  =
  if sig.isClosed:
    return
  sig.isClosed = true
  for fut in sig.waiters:
    failSoon fut
  sig.waiters.setLen 0

when isMainModule:
  discard getGlobalDispatcher()
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
    doAssert not hasPendingOperations()
  block:
    var canceled = false
    var puts = newSeq[int]()
    proc test() {.async.} =
      var sig = newSignal()
      proc waitLoop(x: int) {.async.} =
        while true:
          await sig.waitFor()
          puts.add x
      var fut1 = waitLoop(1)
      var fut2 = waitLoop(2)
      sig.trigger()
      while puts.len != 2:
        await sleepAsync(1)
      while sig.waiters.len != 2:
        await sleepAsync(1)
      sig.close()
      while sig.waiters.len != 0:
        await sleepAsync(1)
      try:
        await (fut1 and fut2)
      except SignalClosedError:
        canceled = true
    waitFor test()
    doAssert puts == @[1, 2]
    doAssert canceled
    doAssert not hasPendingOperations()
  block:
    var canceled = false
    var puts = newSeq[int]()
    proc test() {.async.} =
      var sig = newSignal()
      proc waitLoop(x: int) {.async.} =
        while true:
          await sig.waitFor()
          puts.add x
      var fut1 = waitLoop(1)
      var fut2 = waitLoop(2)
      sig.trigger()
      while puts.len != 2:
        await sleepAsync(1)
      while sig.waiters.len != 2:
        await sleepAsync(1)
      sig.trigger()
      while puts.len != 4:
        await sleepAsync(1)
      while sig.waiters.len != 2:
        await sleepAsync(1)
      sig.close()
      while sig.waiters.len != 0:
        await sleepAsync(1)
      try:
        await (fut1 and fut2)
      except SignalClosedError:
        canceled = true
    waitFor test()
    doAssert puts == @[1, 2, 1, 2]
    doAssert canceled
    doAssert not hasPendingOperations()
  echo "ok"
