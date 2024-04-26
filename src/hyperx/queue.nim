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

proc wakeupNext(dq: Deque[Future[void]]) {.raises: [].} =
  untrackExceptions:
    if dq.len > 0:
      let fut = dq.peekLast()
      if not fut.finished:
        fut.complete()

# XXX we cannot popLast putWaiters in pop()
#     because another async func may run in between
#     waiter complete() and waiter actual run
#     add tests for it?
proc put*[T](q: QueueAsync[T], v: T) {.async.} =
  doAssert q.used <= q.size
  if q.isClosed:
    raise newQueueClosedError()
  if q.used == q.size or q.putWaiters.len > 0:
    q.putWaiters.addFirst newFuture[void]()
    await q.putWaiters.peekFirst()
    if q.isClosed: raise newQueueClosedError()
    discard q.putWaiters.popLast()
  q.s.addFirst v
  doAssert q.used <= q.size
  if q.used < q.size:
    q.putWaiters.wakeupNext()
  q.popWaiters.wakeupNext()

proc pop*[T](q: QueueAsync[T]): Future[T] {.async.} =
  doAssert q.used >= 0
  if q.isClosed:
    raise newQueueClosedError()
  if q.used == 0 or q.popWaiters.len > 0:
    q.popWaiters.addFirst newFuture[void]()
    await q.popWaiters.peekFirst()
    if q.isClosed: raise newQueueClosedError()
    discard q.popWaiters.popLast()
  result = q.s.popLast()
  doAssert q.used >= 0
  if q.used > 0:
    q.popWaiters.wakeupNext()
  q.putWaiters.wakeupNext()

func isClosed*[T](q: QueueAsync[T]): bool {.raises: [].} =
  q.isClosed

proc close*[T](q: QueueAsync[T]) {.raises: [].}  =
  if q.isClosed:
    return
  q.isClosed = true
  untrackExceptions:
    while q.putWaiters.len > 0:
      let fut = q.putWaiters.popLast()
      if not fut.finished:
        fut.fail newQueueClosedError()
  untrackExceptions:
    while q.popWaiters.len > 0:
      let fut = q.popWaiters.popLast()
      if not fut.finished:
        fut.fail newQueueClosedError()

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
      var res = newSeq[int]()
      proc popOne() {.async.} =
        res.add(await q.pop())
      await (
        q.put(1) and
        q.put(2) and
        q.put(3) and
        q.put(4) and
        q.put(5) and
        q.put(6) and
        popOne() and
        popOne() and
        popOne() and
        popOne() and
        popOne() and
        popOne()
      )
      doAssert res == @[1,2,3,4,5,6]
    waitFor test()
  when false:  #block:
    proc test() {.async.} =
      var q = newQueue[int](2)
      var res = newSeq[int]()
      proc popOne() {.async.} =
        res.add(await q.pop())
      await (
        popOne() and
        popOne() and
        popOne() and
        popOne() and
        popOne() and
        popOne() and
        q.put(1) and
        q.put(2) and
        q.put(3) and
        q.put(4) and
        q.put(5) and
        q.put(6)
      )
      doAssert res == @[1,2,3,4,5,6]
    waitFor test()
  when false:  #block:
    proc test() {.async.} =
      var q = newQueue[int](2)
      var res = newSeq[int]()
      proc popOne() {.async.} =
        res.add(await q.pop())
      await (
        popOne() and
        popOne() and
        q.put(1) and
        popOne() and
        q.put(2) and
        popOne() and
        q.put(3) and
        popOne() and
        popOne() and
        q.put(4) and
        q.put(5) and
        q.put(6)
      )
      doAssert res == @[1,2,3,4,5,6]
    waitFor test()
  echo "ok"
