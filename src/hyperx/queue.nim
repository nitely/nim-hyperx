import yasync
import yasync/compat
from std/asyncdispatch import callSoon
import std/deques
import ./utils
import ./errors

func newQueueClosedError(): ref QueueClosedError {.raises: [].} =
  result = (ref QueueClosedError)(msg: "Queue is closed")

type
  QueueAsync*[T] = ref object
    s: Deque[T]
    size: int
    putWaiter, popWaiter: Future[void]
    wakingPut, wakingPop: bool
    isClosed: bool

proc newQueue*[T](size: int): QueueAsync[T] {.raises: [].} =
  doAssert size > 0
  new result
  result = QueueAsync[T](
    s: initDeque[T](size),
    size: size,
    putWaiter: newFuture(void),
    popWaiter: newFuture(void),
    wakingPut: false,
    wakingPop: false,
    isClosed: false
  )
  {.cast(noSideEffect).}:
    result.putWaiter.complete()
    result.popWaiter.complete()

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
    q.putWaiter = newFuture(void)
    await q.putWaiter
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

proc pop*[T](q: QueueAsync[T]): T {.async.} =
  doAssert q.used >= 0
  if q.isClosed:
    raise newQueueClosedError()
  if q.used == 0:
    doAssert q.popWaiter.finished
    q.popWaiter = newFuture(void)
    await q.popWaiter
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
      q.putWaiter.fail newQueueClosedError()
    if not q.popWaiter.finished:
      q.popWaiter.fail newQueueClosedError()
  untrackExceptions:
    callSoon failWaiters

when isMainModule:
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
      let put1 = q.put 1
      let put2 = q.put 2
      doAssert (await q.pop()) == 1
      let put3 = q.put 3
      doAssert (await q.pop()) == 2
      let put4 = q.put 4
      doAssert (await q.pop()) == 4
      await put1
      await put2
      try:
        await put3
        doAssert false
      except AssertionDefect:
        discard
      await put4
    waitFor test()
    doAssert not hasPendingOperations()
  echo "ok"
