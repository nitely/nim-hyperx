import std/asyncdispatch

import ./utils
import ./errors

type LimiterAsyncClosedError* = QueueClosedError

func newLimiterAsyncClosedError(): ref LimiterAsyncClosedError {.raises: [].} =
  result = (ref LimiterAsyncClosedError)(msg: "Limiter is closed")

type LimiterAsync* = ref object
  ## Async concurrency limiter.
  used, size: int
  waiter: Future[void]
  isClosed: bool
  error*: ref Exception

func newLimiter*(size: int): LimiterAsync {.raises: [].} =
  doAssert size > 0
  result = LimiterAsync(
    used: 0,
    size: size,
    waiter: nil,
    isClosed: false
  )

proc wakeupSoon(f: Future[void]) {.raises: [].} =
  if f != nil and not f.finished:
    uncatch f.complete()

proc inc*(lt: LimiterAsync) {.raises: [].} =
  doAssert lt.used < lt.size
  inc lt.used

proc dec*(lt: LimiterAsync) {.raises: [].} =
  doAssert lt.used > 0
  dec lt.used
  wakeupSoon lt.waiter

proc isFull*(lt: LimiterAsync): bool {.raises: [].} =
  lt.used == lt.size

proc isEmpty*(lt: LimiterAsync): bool {.raises: [].} =
  lt.used == 0

proc wait*(lt: LimiterAsync): Future[void] {.raises: [LimiterAsyncClosedError].} =
  doAssert lt.used > 0
  doAssert lt.used <= lt.size
  doAssert lt.waiter == nil or lt.waiter.finished
  check not lt.isClosed, newLimiterAsyncClosedError()
  lt.waiter = newFuture[void]()
  return lt.waiter

proc failSoon(f: Future[void]) {.raises: [].} =
  if f != nil and not f.finished:
    uncatch f.fail newLimiterAsyncClosedError()

proc close*(lt: LimiterAsync) {.raises: [].} =
  if lt.isClosed:
    return
  lt.isClosed = true
  failSoon lt.waiter

proc spawnCheck*(lt: LimiterAsync, f: Future[void]) {.raises: [LimiterAsyncClosedError].} =
  check not lt.isClosed, newLimiterAsyncClosedError()
  inc lt
  uncatch f.addCallback(proc () {.raises: [].} =
    dec lt
    if f.failed:
      lt.error ?= f.error
  )

proc spawn*(lt: LimiterAsync, f: Future[void]) {.async.} =
  lt.spawnCheck f
  if lt.isFull:
    await lt.wait()

proc join*(lt: LimiterAsync) {.async.} =
  while not lt.isEmpty:
    await lt.wait()
  check lt.error == nil, lt.error

when isMainModule:
  discard getGlobalDispatcher()
  proc sleepCycle: Future[void] =
    let fut = newFuture[void]()
    proc wakeup = fut.complete()
    callSoon wakeup
    return fut
  type MyError = object of CatchableError
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
  block:
    proc test {.async.} =
      proc noop {.async.} =
        for _ in 0 .. 10:
          await sleepCycle()
      proc err {.async.} =
        raise (ref MyError)()
      let lt = newLimiter int.high
      for i in 0 ..< 5:
        lt.spawnCheck noop()
      lt.spawnCheck err()
      try:
        await lt.join()
        doAssert false
      except MyError:
        discard
    waitFor test()
    doAssert not hasPendingOperations()
  echo "ok"
