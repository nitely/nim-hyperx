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
  isClosed: bool

func newLimiter*(size: int): LimiterAsync {.raises: [].} =
  doAssert size > 0
  result = LimiterAsync(
    used: 0,
    size: size,
    waiter: newFutureVar[void](),
    isClosed: false
  )
  {.cast(noSideEffect).}:
    uncatch result.waiter.complete()

proc wakeup(lt: LimiterAsync) {.raises: [].} =
  if not lt.waiter.finished:
    uncatch lt.waiter.complete()

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
  if not lt.waiter.finished:
    uncatch lt.waiter.fail newLimiterAsyncClosedError()

proc close*(lt: LimiterAsync) {.raises: [].} =
  if lt.isClosed:
    return
  lt.isClosed = true
  failSoon lt

proc limiterWrap(lt: LimiterAsync, f: Future[void]) {.async.} =
  try:
    await f
  finally:
    dec lt

proc spawn*(lt: LimiterAsync, f: Future[void]) {.async.} =
  inc lt
  asyncCheck limiterWrap(lt, f)
  if lt.isFull:
    await lt.wait()

proc join*(lt: LimiterAsync) {.async.} =
  while not lt.isEmpty:
    await lt.wait()

when isMainModule:
  discard getGlobalDispatcher()
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
