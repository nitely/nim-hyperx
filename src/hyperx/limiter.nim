import std/asyncdispatch

import ./utils
import ./errors

template fut[T](f: FutureVar[T]): Future[T] = Future[T](f)

type LimiterAsyncClosedError* = QueueClosedError

func newLimiterAsyncClosedError(): ref LimiterAsyncClosedError {.raises: [].} =
  result = (ref LimiterAsyncClosedError)(msg: "Limiter is closed")

type LimiterAsync* = ref object
  ## Async concurrency limiter.
  used, size: int
  waiter: FutureVar[void]
  wakingUp: bool
  isClosed: bool

func newLimiter*(size: int): LimiterAsync {.raises: [].} =
  doAssert size > 0
  {.cast(noSideEffect).}:
    let waiter = newFutureVar[void]()
    untrackExceptions:
      waiter.complete()
    LimiterAsync(
      used: 0,
      size: size,
      waiter: waiter,
      wakingUp: false,
      isClosed: false
    )

proc wakeup(lt: LimiterAsync) {.raises: [].} =
  if lt.waiter.finished:
    return
  proc wakeup =
    lt.wakingUp = false
    if not lt.waiter.finished:
      lt.waiter.complete()
  if not lt.wakingUp:
    lt.wakingUp = true
    untrackExceptions:
      callSoon wakeup

proc inc*(lt: LimiterAsync) {.raises: [LimiterAsyncClosedError].} =
  doAssert lt.used < lt.size
  check not lt.isClosed, newLimiterAsyncClosedError()
  inc lt.used

proc dec*(lt: LimiterAsync) {.raises: [LimiterAsyncClosedError].} =
  doAssert lt.used > 0
  check not lt.isClosed, newLimiterAsyncClosedError()
  dec lt.used
  wakeup lt

proc isFull*(lt: LimiterAsync): bool {.raises: [].} =
  lt.used == lt.size

proc isEmpty*(lt: LimiterAsync): bool {.raises: [].} =
  lt.used == 0

proc wait*(lt: LimiterAsync): Future[void] {.raises: [LimiterAsyncClosedError].} =
  doAssert lt.used > 0
  doAssert lt.used <= lt.size
  doAssert lt.waiter.finished
  check not lt.isClosed, newLimiterAsyncClosedError()
  lt.waiter.clean()
  return lt.waiter.fut

proc failSoon(lt: LimiterAsync) {.raises: [].} =
  if lt.waiter.finished:
    return
  proc wakeup =
    lt.wakingUp = false
    if not lt.waiter.finished:
      lt.waiter.fut.fail newLimiterAsyncClosedError()
  if not lt.wakingUp:
    lt.wakingUp = true
    untrackExceptions:
      callSoon wakeup

proc close*(lt: LimiterAsync) {.raises: [].} =
  if lt.isClosed:
    return
  lt.isClosed = true
  failSoon lt

when isMainModule:
  proc sleepCycle: Future[void] =
    let fut = newFuture[void]()
    proc wakeup = fut.complete()
    callSoon wakeup
    return fut
  block:
    proc test {.async.} =
      let lt = newLimiter(1)
      var puts = newSeq[int]()
      proc putOne(i: int) {.async.} =
        puts.add i
        dec lt
      for i in 1 .. 6:
        inc lt
        asyncCheck putOne(i)
        if lt.isFull:
          await lt.wait()
        doAssert puts.len == i
        doAssert lt.used <= 1
      doAssert puts == @[1,2,3,4,5,6]
    waitFor test()
    doAssert not hasPendingOperations()
  block:
    proc test {.async.} =
      let lt = newLimiter(1)
      var puts = newSeq[int]()
      proc putOne(i: int) {.async.} =
        for _ in 0 .. 10:
          await sleepCycle()
        puts.add i
        dec lt
      for i in 1 .. 6:
        inc lt
        asyncCheck putOne(i)
        if lt.isFull:
          await lt.wait()
        doAssert puts.len == i
        doAssert lt.used <= 1
      doAssert puts == @[1,2,3,4,5,6]
    waitFor test()
    doAssert not hasPendingOperations()
  block:
    proc test {.async.} =
      let lt = newLimiter(2)
      var puts = newSeq[int]()
      proc putOne(i: int) {.async.} =
        for _ in 0 .. 10:
          await sleepCycle()
        puts.add i
        dec lt
      for i in 1 .. 6:
        inc lt
        asyncCheck putOne(i)
        if lt.isFull:
          await lt.wait()
        doAssert lt.used <= 2
      doAssert puts == @[1,2,3,4,5,6]
    waitFor test()
    doAssert not hasPendingOperations()
  echo "ok"