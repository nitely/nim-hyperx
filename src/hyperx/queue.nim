import std/asyncdispatch
import std/deques

type
  QueueAsync*[T] = ref object
    s: Deque[T]
    size, used: int
    # XXX use/reuse FutureVars
    putEv, popEv: Deque[Future[void]]

proc newQueue*[T](size: int): QueueAsync[T] =
  doAssert size > 0
  new result
  result = QueueAsync[T](
    s: initDeque[T](size),
    size: size,
    used: 0,
    putEv: initDeque[Future[void]](2),
    popEv: initDeque[Future[void]](2)
  )

proc popEvent[T](q: QueueAsync[T]): Future[void] =
  result = newFuture[void]()
  q.popEv.addLast result

proc popDone[T](q: QueueAsync[T]) =
  if q.popEv.len > 0:
    q.popEv.popFirst().complete()

proc putEvent[T](q: QueueAsync[T]): Future[void] =
  result = newFuture[void]()
  q.putEv.addLast result

proc putDone[T](q: QueueAsync[T]) =
  if q.putEv.len > 0:
    q.putEv.popFirst().complete()

proc put*[T](q: QueueAsync[T], v: T) {.async.} =
  doAssert q.used <= q.size
  if q.used == q.size:
    await q.popEvent()
  q.s.addFirst v
  inc q.used
  doAssert q.used <= q.size
  q.putDone()

proc pop*[T](q: QueueAsync[T]): Future[T] {.async.} =
  doAssert q.used >= 0
  if q.used == 0:
    await q.putEvent()
  result = q.s.popLast()
  dec q.used
  doAssert q.used >= 0
  q.popDone()

when isMainModule:
  block:
    proc test() {.async.} =
      var q = newQueue[int](2)
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
  echo "ok"
