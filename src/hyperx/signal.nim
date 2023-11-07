# XXX: remove if not used

import std/asyncdispatch
import std/deques

type
  SignalAsync* = ref object
    ## Akin to a queue of size one
    used: bool
    # XXX use/reuse FutureVars
    putEv, popEv: Deque[Future[void]]

proc newSignal*(): SignalAsync =
  new result
  result = SignalAsync(
    used: false,
    putEv: initDeque[Future[void]](2),
    popEv: initDeque[Future[void]](2)
  )

proc popEvent(sgn: SignalAsync): Future[void] =
  result = newFuture[void]()
  sgn.popEv.addLast result

proc popDone(sgn: SignalAsync) =
  if sgn.popEv.len > 0:
    sgn.popEv.popFirst().complete()

proc putEvent(sgn: SignalAsync): Future[void] =
  result = newFuture[void]()
  sgn.putEv.addLast result

proc putDone(sgn: SignalAsync) =
  if sgn.putEv.len > 0:
    sgn.putEv.popFirst().complete()

proc put*(sgn: SignalAsync): Future[void] {.async.} =
  if sgn.used:
    await sgn.popEvent()
  sgn.used = true
  sgn.putDone()

proc pop*(sgn: SignalAsync): Future[void] {.async.} =
  if not sgn.used:
    await sgn.putEvent()
  sgn.used = false
  sgn.popDone()

when isMainModule:
  block:
    proc test() {.async.} =
      var sgn = newSignal()
      await sgn.put()
      await sgn.pop()
      await sgn.put()
      await sgn.pop()
    waitFor test()
  block:
    proc test() {.async.} =
      var sgn = newSignal()
      var resPut = newSeq[int]()
      var resPop = newSeq[int]()
      proc putOne(i: int) {.async.} =
        await sgn.put()
        resPut.add i
      proc popOne(i: int) {.async.} =
        await sgn.pop()
        resPop.add i
      await (
        putOne(1) and
        putOne(2) and
        putOne(3) and
        putOne(4) and
        putOne(5) and
        putOne(6) and
        popOne(1) and
        popOne(2) and
        popOne(3) and
        popOne(4) and
        popOne(5) and
        popOne(6)
      )
      doAssert resPut == @[1,2,3,4,5,6]
      doAssert resPop == @[1,2,3,4,5,6]
    waitFor test()
  echo "ok"
