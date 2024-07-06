import std/asyncdispatch
import std/deques
import ./utils
import ./errors

func newQueueClosedError(): ref QueueClosedError {.raises: [].} =
  result = (ref QueueClosedError)(msg: "Queue is closed")

# this does not support multi-receivers/senders
# it used to support it but the code was iffy
# https://gist.github.com/nitely/e952f5ce98547e2f7e858a38869341dd
type
  QueueAsync*[T] = ref object
    s: Deque[T]
    size: int
    putWaiter, popWaiter: FutureVar[void]
    wakingPut, wakingPop: bool
    isClosed: bool

proc newQueue*[T](size: int): QueueAsync[T] {.raises: [].} =
  doAssert size > 0
  new result
  {.cast(noSideEffect).}:
    result = QueueAsync[T](
      s: initDeque[T](size),
      size: size,
      putWaiter: newFutureVar[void](),
      popWaiter: newFutureVar[void](),
      wakingPut: false,
      wakingPop: false,
      isClosed: false
    )
    untrackExceptions:
      result.putWaiter.complete()
      result.popWaiter.complete()

iterator items*[T](q: QueueAsync[T]): T {.inline.} =
  for elm in items q.s:
    yield elm

func used[T](q: QueueAsync[T]): int {.raises: [].} =
  q.s.len

proc wakeupPop[T](q: QueueAsync[T]) =
  if q.popWaiter.finished:
    return
  proc wakeup =
    q.wakingPop = false
    if not q.popWaiter.finished:
      q.popWaiter.complete()
  if not q.wakingPop:
    q.wakingPop = true
    untrackExceptions:
      callSoon wakeup

proc put*[T](q: QueueAsync[T], v: T) {.async.} =
  doAssert q.used <= q.size
  if q.isClosed:
    raise newQueueClosedError()
  if q.used == q.size:
    doAssert q.putWaiter.finished
    q.putWaiter.clean()
    await Future[void](q.putWaiter)
    if q.isClosed:
      raise newQueueClosedError()
  doAssert q.putWaiter.finished
  doAssert q.used < q.size
  q.s.addFirst v
  q.wakeupPop()

proc wakeupPut[T](q: QueueAsync[T]) =
  if q.putWaiter.finished:
    return
  proc wakeup =
    q.wakingPut = false
    if not q.putWaiter.finished:
      q.putWaiter.complete()
  if not q.wakingPut:
    q.wakingPut = true
    untrackExceptions:
      callSoon wakeup

proc pop*[T](q: QueueAsync[T]): Future[T] {.async.} =
  doAssert q.used >= 0
  if q.isClosed:
    raise newQueueClosedError()
  if q.used == 0:
    doAssert q.popWaiter.finished
    q.popWaiter.clean()
    await Future[void](q.popWaiter)
    if q.isClosed:
      raise newQueueClosedError()
  doAssert q.popWaiter.finished
  doAssert q.used > 0
  result = q.s.popLast()
  q.wakeupPut()

func isClosed*[T](q: QueueAsync[T]): bool {.raises: [].} =
  q.isClosed

proc close*[T](q: QueueAsync[T]) {.raises: [].}  =
  if q.isClosed:
    return
  q.isClosed = true
  proc failWaiters =
    if not q.putWaiter.finished:
      Future[void](q.putWaiter).fail newQueueClosedError()
    if not q.popWaiter.finished:
      Future[void](q.popWaiter).fail newQueueClosedError()
  untrackExceptions:
    callSoon failWaiters

when isMainModule:
  proc sleepy(x: int) {.async.} =
    doAssert x > 0
    for _ in 0 .. x-1:
      await sleepAsync(1)
  block:
    proc test() {.async.} =
      var q = newQueue[int](1)
      await q.put 1
      doAssert (await q.pop()) == 1
      await q.put 2
      doAssert (await q.pop()) == 2
      await q.put 3
      doAssert (await q.pop()) == 3
      await q.put 4
      doAssert (await q.pop()) == 4
    waitFor test()
    doAssert not hasPendingOperations()
  block:
    proc test() {.async.} =
      var q = newQueue[int](1)
      proc puts {.async.} =
        await q.put 1
        await q.put 2
        await q.put 3
        await q.put 4
      let puts1 = puts()
      doAssert (await q.pop()) == 1
      doAssert (await q.pop()) == 2
      doAssert (await q.pop()) == 3
      doAssert (await q.pop()) == 4
      await puts1
    waitFor test()
    doAssert not hasPendingOperations()
  block:
    proc test() {.async.} =
      var q = newQueue[int](1)
      proc puts {.async.} =
        await sleepy(10)
        await q.put 1
        await sleepy(10)
        await q.put 2
        await sleepy(10)
        await q.put 3
        await sleepy(10)
        await q.put 4
      let puts1 = puts()
      doAssert (await q.pop()) == 1
      doAssert (await q.pop()) == 2
      doAssert (await q.pop()) == 3
      doAssert (await q.pop()) == 4
      await puts1
    waitFor test()
    doAssert not hasPendingOperations()
  block:
    proc test() {.async.} =
      var q = newQueue[int](1)
      proc puts {.async.} =
        await q.put 1
        await q.put 2
        await q.put 3
        await q.put 4
      let puts1 = puts()
      doAssert (await q.pop()) == 1
      await sleepy(10)
      doAssert (await q.pop()) == 2
      await sleepy(10)
      doAssert (await q.pop()) == 3
      await sleepy(10)
      doAssert (await q.pop()) == 4
      await puts1
    waitFor test()
    doAssert not hasPendingOperations()
  block:
    proc test() {.async.} =
      var q = newQueue[int](1)
      proc pops {.async.} =
        doAssert (await q.pop()) == 1
        doAssert (await q.pop()) == 2
        doAssert (await q.pop()) == 3
        doAssert (await q.pop()) == 4
      let pops1 = pops()
      await q.put 1
      await q.put 2
      await q.put 3
      await q.put 4
      await pops1
    waitFor test()
    doAssert not hasPendingOperations()
  block:
    proc test() {.async.} =
      var q = newQueue[int](1)
      proc pops {.async.} =
        doAssert (await q.pop()) == 1
        doAssert (await q.pop()) == 2
        doAssert (await q.pop()) == 3
        doAssert (await q.pop()) == 4
      proc puts {.async.} =
        await q.put 1
        await q.put 2
        await q.put 3
        await q.put 4
      let pops1 = pops()
      let puts1 = puts()
      await pops1
      await puts1
    waitFor test()
    doAssert not hasPendingOperations()
  block:
    proc test() {.async.} =
      var q = newQueue[int](1)
      proc pops {.async.} =
        await sleepy(2)
        doAssert (await q.pop()) == 1
        await sleepy(4)
        doAssert (await q.pop()) == 2
        await sleepy(8)
        doAssert (await q.pop()) == 3
        await sleepy(16)
        doAssert (await q.pop()) == 4
      proc puts {.async.} =
        await sleepy(16)
        await q.put 1
        await sleepy(8)
        await q.put 2
        await sleepy(4)
        await q.put 3
        await sleepy(2)
        await q.put 4
      let pops1 = pops()
      let puts1 = puts()
      await pops1
      await puts1
    waitFor test()
    doAssert not hasPendingOperations()
  block:
    proc test() {.async.} =
      var q = newQueue[int](1)
      proc pops {.async.} =
        await sleepy(16)
        doAssert (await q.pop()) == 1
        await sleepy(8)
        doAssert (await q.pop()) == 2
        await sleepy(4)
        doAssert (await q.pop()) == 3
        await sleepy(2)
        doAssert (await q.pop()) == 4
      proc puts {.async.} =
        await sleepy(2)
        await q.put 1
        await sleepy(4)
        await q.put 2
        await sleepy(8)
        await q.put 3
        await sleepy(16)
        await q.put 4
      let pops1 = pops()
      let puts1 = puts()
      await pops1
      await puts1
    waitFor test()
    doAssert not hasPendingOperations()
  block:  # multiple senders not allowed
    proc test() {.async.} =
      var q = newQueue[int](1)
      let put1 = q.put 1
      let put2 = q.put 2
      let put3 = q.put 3
      try:
        await put3
        raise newException(Defect, "assertion raise expected")
      except AssertionDefect:
        discard
      q.close()
      await put1
      try:
        await put2
        doAssert false
      except QueueClosedError:
        discard
    waitFor test()
    doAssert not hasPendingOperations()
  block:  # multiple receivers not allowed
    proc test() {.async.} =
      var q = newQueue[int](1)
      await q.put 1
      let pop1 = q.pop()
      let pop2 = q.pop()
      let pop3 = q.pop()
      try:
        discard await pop3
        raise newException(Defect, "assertion raise expected")
      except AssertionDefect:
        discard
      doAssert (await pop1) == 1
      q.close()
      try:
        discard await pop2
        doAssert false
      except QueueClosedError:
        discard
    waitFor test()
    doAssert not hasPendingOperations()
  echo "ok"
