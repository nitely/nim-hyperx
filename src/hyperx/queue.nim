import std/asyncdispatch
import std/deques

type
  CircularQ*[T] = ref object
    s: seq[T]
    wi, ri: int
    # XXX use/reuse FutureVars
    putEv, popEv: Deque[Future[void]]

proc newCircularQ*[T](size: Natural): CircularQ[T] =
  doAssert size >= 2
  new result
  result = CircularQ[T](
    s: newSeq[T](size),
    wi: 0,
    ri: 0,
    putEv: initDeque[Future[void]](),
    popEv: initDeque[Future[void]]()
  )

proc popEvent[T](q: CircularQ[T]): Future[void] =
  result = newFuture[void]()
  q.popEv.addLast result

proc popDone[T](q: CircularQ[T]) =
  if q.popEv.len > 0:
    q.popEv.popFirst().complete()

proc putEvent[T](q: CircularQ[T]): Future[void] =
  result = newFuture[void]()
  q.putEv.addLast result

proc putDone[T](q: CircularQ[T]) =
  if q.putEv.len > 0:
    q.putEv.popFirst().complete()

proc put*[T](q: CircularQ[T], v: T) {.async.} =
  if (q.wi+1) mod q.s.len == q.ri:
    await q.popEvent()
  doAssert (q.wi+1) mod q.s.len != q.ri
  q.s[q.wi] = v
  q.wi = (q.wi+1) mod q.s.len
  q.putDone()

proc pop*[T](q: CircularQ[T]): Future[T] {.async.} =
  if q.wi == q.ri:
    await q.putEvent()
  doAssert q.wi != q.ri
  result = q.s[q.ri]
  q.ri = (q.ri+1) mod q.s.len
  q.popDone()

when isMainModule:
  block:
    proc test() {.async.} =
      var q = newCircularQ[int](2)
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
      var q = newCircularQ[int](2)
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
