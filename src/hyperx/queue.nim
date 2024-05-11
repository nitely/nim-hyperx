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

proc wakeupPopWaiterSoon[T](q: QueueAsync[T]) =
  if q.popWaiters.len == 0:
    return
  proc wakeup =
    if q.popWaiters.len > 0:
      let f = q.popWaiters.popLast()
      if not f.finished:
        f.complete()
  untrackExceptions:
    callSoon wakeup

proc put*[T](q: QueueAsync[T], v: T) {.async.} =
  doAssert q.used <= q.size
  if q.isClosed:
    raise newQueueClosedError()
  if q.used == q.size or q.putWaiters.len > 0:
    let fut = newFuture(void)
    q.putWaiters.addFirst fut
    await fut
  doAssert q.used < q.size
  q.s.addFirst v
  q.wakeupPopWaiterSoon()

proc wakeupPutWaiterSoon[T](q: QueueAsync[T]) =
  if q.putWaiters.len == 0:
    return
  proc wakeup =
    if q.putWaiters.len > 0:
      let f = q.putWaiters.popLast()
      if not f.finished:
        f.complete()
  untrackExceptions:
    callSoon wakeup

proc pop*[T](q: QueueAsync[T]): T {.async.} =
  doAssert q.used >= 0
  if q.isClosed:
    raise newQueueClosedError()
  if q.used == 0 or q.popWaiters.len > 0:
    let fut = newFuture(void)
    q.popWaiters.addFirst fut
    await fut
  doAssert q.used > 0
  result = q.s.popLast()
  q.wakeupPutWaiterSoon()

func isClosed*[T](q: QueueAsync[T]): bool {.raises: [].} =
  q.isClosed

proc failSoon(f: Future[void]) =
  proc wakeup =
    if not f.finished:
      f.fail newQueueClosedError()
  untrackExceptions:
    callSoon wakeup

proc close*[T](q: QueueAsync[T]) {.raises: [].}  =
  if q.isClosed:
    return
  q.isClosed = true
  while q.putWaiters.len > 0:
    failSoon q.putWaiters.popLast()
  while q.popWaiters.len > 0:
    failSoon q.popWaiters.popLast()

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
  block race_condition:
    proc test() {.async.} =
      var q = newQueue[int](1)
      let put1 = q.put 1
      let put2 = q.put 2
      doAssert (await q.pop()) == 1
      let put3 = q.put 3
      let put4 = q.put 4
      doAssert (await q.pop()) == 2
      doAssert (await q.pop()) == 3
      await (put1 and put2 and put3 and put4)
      doAssert (await q.pop()) == 4
    waitFor test()
  echo "ok"
