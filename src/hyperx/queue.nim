import std/asyncdispatch
import std/deques
import ./utils
import ./errors

func newQueueClosedError(): ref QueueClosedError {.raises: [].} =
  result = (ref QueueClosedError)(msg: "Queue is closed")

type
  QueueAsync*[T] = ref object
    s: Deque[T]
    size: int
    # XXX use/reuse FutureVars
    putWaiters, popWaiters: Deque[Future[void]]
    isClosed: bool

proc newQueue*[T](size: int): QueueAsync[T] {.raises: [].} =
  doAssert size > 0
  new result
  result = QueueAsync[T](
    s: initDeque[T](size),
    size: size,
    putWaiters: initDeque[Future[void]](2),
    popWaiters: initDeque[Future[void]](2),
    isClosed: false
  )

func used[T](q: QueueAsync[T]): int {.raises: [].} =
  q.s.len

proc wakeupLastPut[T](q: QueueAsync[T]) {.raises: [].} =
  proc wakeup =
    if q.used == q.size:
      return
    if q.putWaiters.len > 0:
      let fut = q.putWaiters.peekLast()
      if not fut.finished:
        fut.complete()
  untrackExceptions:
    callSoon wakeup

proc wakeupLastPop[T](q: QueueAsync[T]) {.raises: [].} =
  proc wakeup =
    if q.used == 0:
      return
    if q.popWaiters.len > 0:
      let fut = q.popWaiters.peekLast()
      if not fut.finished:
        fut.complete()
  untrackExceptions:
    callSoon wakeup

# XXX we cannot popLast putWaiters in pop()
#     because another async func may run in between
#     waiter complete() and waiter actual run
#     add tests for it?
proc put*[T](q: QueueAsync[T], v: T) {.async.} =
  doAssert q.used <= q.size
  if q.isClosed:
    raise newQueueClosedError()
  if q.used == q.size or q.putWaiters.len > 0:
    let fut = newFuture[void]()
    q.putWaiters.addFirst fut
    await fut
    if q.isClosed:
      raise newQueueClosedError()
    let fut2 = q.putWaiters.popLast()
    doAssert fut == fut2
  doAssert q.used < q.size
  q.s.addFirst v
  q.wakeupLastPut()
  q.wakeupLastPop()

proc pop*[T](q: QueueAsync[T]): Future[T] {.async.} =
  doAssert q.used >= 0
  if q.isClosed:
    raise newQueueClosedError()
  if q.used == 0 or q.popWaiters.len > 0:
    let fut = newFuture[void]()
    q.popWaiters.addFirst fut
    await fut
    if q.isClosed:
      raise newQueueClosedError()
    let fut2 = q.popWaiters.popLast()
    doAssert fut == fut2
  doAssert q.used > 0
  result = q.s.popLast()
  q.wakeupLastPop()
  q.wakeupLastPut()

func isClosed*[T](q: QueueAsync[T]): bool {.raises: [].} =
  q.isClosed

proc close*[T](q: QueueAsync[T]) {.raises: [].}  =
  if q.isClosed:
    return
  q.isClosed = true
  proc failWaiters =
    while q.putWaiters.len > 0:
      let fut = q.putWaiters.popLast()
      if not fut.finished:
        fut.fail newQueueClosedError()
    while q.popWaiters.len > 0:
      let fut = q.popWaiters.popLast()
      if not fut.finished:
        fut.fail newQueueClosedError()
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
  block:
    proc test() {.async.} =
      var q = newQueue[int](2)
      var puts = newSeq[int]()
      var pops = newSeq[int]()
      proc putOne(x: int) {.async.} =
        await q.put(x)
        puts.add x
      proc popOne() {.async.} =
        pops.add(await q.pop())
      await (
        putOne(1) and
        putOne(2) and
        putOne(3) and
        putOne(4) and
        putOne(5) and
        putOne(6) and
        popOne() and
        popOne() and
        popOne() and
        popOne() and
        popOne() and
        popOne()
      )
      doAssert puts == @[1,2,3,4,5,6]
      doAssert pops == @[1,2,3,4,5,6]
    waitFor test()
  block:
    proc test() {.async.} =
      var q = newQueue[int](2)
      var puts = newSeq[int]()
      var pops = newSeq[int]()
      proc putOne(x: int) {.async.} =
        await q.put(x)
        puts.add x
      proc popOne() {.async.} =
        pops.add(await q.pop())
      await (
        popOne() and
        popOne() and
        popOne() and
        popOne() and
        popOne() and
        popOne() and
        putOne(1) and
        putOne(2) and
        putOne(3) and
        putOne(4) and
        putOne(5) and
        putOne(6)
      )
      doAssert puts == @[1,2,3,4,5,6]
      doAssert pops == @[1,2,3,4,5,6]
    waitFor test()
  block:
    proc test() {.async.} =
      var q = newQueue[int](2)
      var puts = newSeq[int]()
      var pops = newSeq[int]()
      proc putOne(x: int) {.async.} =
        await q.put(x)
        puts.add x
      proc popOne() {.async.} =
        pops.add(await q.pop())
      await (
        popOne() and
        popOne() and
        putOne(1) and
        popOne() and
        putOne(2) and
        popOne() and
        putOne(3) and
        popOne() and
        popOne() and
        putOne(4) and
        putOne(5) and
        putOne(6)
      )
      doAssert puts == @[1,2,3,4,5,6]
      doAssert pops == @[1,2,3,4,5,6]
    waitFor test()
  echo "ok"
