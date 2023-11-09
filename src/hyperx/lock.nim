import std/asyncdispatch
import std/deques

type
  LockAsync* = ref object
    ## Akin to a queue of size one
    used: bool
    # XXX use/reuse FutureVars
    relEv: Deque[Future[void]]

proc newLock*(): LockAsync =
  new result
  result = LockAsync(
    used: false,
    relEv: initDeque[Future[void]](2)
  )

proc relEvent(lck: LockAsync): Future[void] =
  result = newFuture[void]()
  lck.relEv.addLast result

proc relDone(lck: LockAsync) =
  if lck.relEv.len > 0:
    lck.relEv.popFirst().complete()

proc acquire(lck: LockAsync): Future[void] {.async.} =
  if lck.used:
    await lck.relEvent()
  lck.used = true

proc release(lck: LockAsync) =
  doAssert lck.used
  lck.used = false
  lck.relDone()

template withLock*(lck: LockAsync, body: untyped): untyped =
  await lck.acquire()
  try:
    body
  finally:
    lck.release()

when isMainModule:
  block:
    proc test() {.async.} =
      var lck = newLock()
      await lck.acquire()
      lck.release()
      await lck.acquire()
      lck.release()
    waitFor test()
  block:
    proc test() {.async.} =
      var lck = newLock()
      var resPut = newSeq[int]()
      var resPop = newSeq[int]()
      proc putOne(i: int) {.async.} =
        await lck.acquire()
        resPut.add i
      proc popOne(i: int) {.async.} =
        lck.release()
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
  block:
    proc test() {.async.} =
      var lck = newLock()
      var puts = newSeq[int]()
      proc putOne(i: int) {.async.} =
        withLock lck:
          puts.add i
      await (
        putOne(1) and
        putOne(2) and
        putOne(3) and
        putOne(4) and
        putOne(5) and
        putOne(6)
      )
      doAssert puts == @[1,2,3,4,5,6]
    waitFor test()
  echo "ok"
