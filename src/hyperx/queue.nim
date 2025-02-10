import std/asyncdispatch
import std/deques
import ./utils
import ./errors

template fut[T](f: FutureVar[T]): Future[T] = Future[T](f)

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
    isClosed: bool

func newQueue*[T](size: int): QueueAsync[T] {.raises: [].} =
  doAssert size > 0
  result = QueueAsync[T](
    s: initDeque[T](size),
    size: size,
    putWaiter: newFutureVar[void](),
    popWaiter: newFutureVar[void](),
    isClosed: false
  )
  {.cast(noSideEffect).}:
    uncatch result.putWaiter.complete()
    uncatch result.popWaiter.complete()

iterator items*[T](q: QueueAsync[T]): T {.inline.} =
  for elm in items q.s:
    yield elm

func used[T](q: QueueAsync[T]): int {.raises: [].} =
  q.s.len

proc wakeupPop[T](q: QueueAsync[T]) {.raises: [].} =
  if not q.popWaiter.finished:
    uncatch q.popWaiter.complete()

proc put*[T](q: QueueAsync[T], v: T) {.async.} =
  doAssert q.used <= q.size
  check not q.isClosed, newQueueClosedError()
  doAssert q.putWaiter.finished
  if q.used == q.size:
    q.putWaiter.clean()
    await q.putWaiter.fut
    check not q.isClosed, newQueueClosedError()
  doAssert q.used < q.size
  q.s.addFirst v
  q.wakeupPop()

proc wakeupPut[T](q: QueueAsync[T]) {.raises: [].} =
  if not q.putWaiter.finished:
    uncatch q.putWaiter.complete()

proc pop*[T](q: QueueAsync[T]): Future[T] {.async.} =
  doAssert q.used >= 0
  check not q.isClosed, newQueueClosedError()
  doAssert q.popWaiter.finished
  if q.used == 0:
    q.popWaiter.clean()
    await q.popWaiter.fut
    check not q.isClosed, newQueueClosedError()
  doAssert q.used > 0
  result = q.s.popLast()
  q.wakeupPut()

func isClosed*[T](q: QueueAsync[T]): bool {.raises: [].} =
  q.isClosed

proc failSoon(f: Future[void]) {.raises: [].} =
  if not f.finished:
    uncatch f.fail newQueueClosedError()

proc close*[T](q: QueueAsync[T]) {.raises: [].}  =
  if q.isClosed:
    return
  q.isClosed = true
  failSoon q.putWaiter.fut
  failSoon q.popWaiter.fut

when isMainModule:
  discard getGlobalDispatcher()
  proc sleepCycle: Future[void] =
    let fut = newFuture[void]()
    proc wakeup = fut.complete()
    callSoon wakeup
    return fut
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
        await sleepCycle()
        await q.put 1
        await sleepCycle()
        await q.put 2
        await sleepCycle()
        await q.put 3
        await sleepCycle()
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
      await sleepCycle()
      doAssert (await q.pop()) == 2
      await sleepCycle()
      doAssert (await q.pop()) == 3
      await sleepCycle()
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
        await sleepCycle()
        doAssert (await q.pop()) == 1
        await sleepCycle()
        doAssert (await q.pop()) == 2
        await sleepCycle()
        doAssert (await q.pop()) == 3
        await sleepCycle()
        doAssert (await q.pop()) == 4
      proc puts {.async.} =
        await sleepCycle()
        await q.put 1
        await sleepCycle()
        await q.put 2
        await sleepCycle()
        await q.put 3
        await sleepCycle()
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
        await sleepCycle()
        doAssert (await q.pop()) == 1
        await sleepCycle()
        doAssert (await q.pop()) == 2
        await sleepCycle()
        doAssert (await q.pop()) == 3
        await sleepCycle()
        doAssert (await q.pop()) == 4
      proc puts {.async.} =
        await sleepCycle()
        await q.put 1
        await sleepCycle()
        await q.put 2
        await sleepCycle()
        await q.put 3
        await sleepCycle()
        await q.put 4
      let pops1 = pops()
      let puts1 = puts()
      await pops1
      await puts1
    waitFor test()
    doAssert not hasPendingOperations()
  echo "ok"
