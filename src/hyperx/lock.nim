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
  doAssert(not lck.used)
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
      var res: seq[string]
      var lck = newLock()
      proc acquire(i: int) {.async.} =
        await lck.acquire()
        res.add "acq" & $i
      proc release(i: int) {.async.} =
        res.add "rel" & $i
        lck.release()
      await acquire(1)
      await (
        acquire(2) and
        release(1)
      )
      await release(2)
      doAssert res == @["acq1", "rel1", "acq2", "rel2"]
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
  block:
    proc test() {.async.} =
      var lck = newLock()
      proc release() {.async.} =
        lck.release()
      var puts = newSeq[int]()
      proc putOne(i: int) {.async.} =
        withLock lck:
          puts.add i
      await lck.acquire()
      await (
        putOne(1) and
        putOne(2) and
        putOne(3) and
        putOne(4) and
        putOne(5) and
        putOne(6) and
        release()
      )
      doAssert puts == @[1,2,3,4,5,6]
    waitFor test()
  echo "ok"
