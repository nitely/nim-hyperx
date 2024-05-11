import std/asyncdispatch
import std/deques

import ./utils
import ./errors

type
  LockClosedError* = QueueClosedError

func newLockClosedError(): ref LockClosedError {.raises: [].} =
  result = (ref LockClosedError)(msg: "Lock is closed")

type
  LockAsync* = ref object
    ## Akin to a queue of size one
    used: bool
    # XXX use/reuse FutureVars
    waiters: Deque[Future[void]]
    isClosed: bool

proc newLock*(): LockAsync {.raises: [].} =
  new result
  result = LockAsync(
    used: false,
    waiters: initDeque[Future[void]](0),
    isClosed: false
  )

proc acquire(lck: LockAsync) {.async.} =
  if lck.isClosed:
    raise newLockClosedError()
  if lck.used or lck.waiters.len > 0:
    let fut = newFuture[void]()
    lck.waiters.addFirst fut
    await fut
  doAssert(not lck.used)
  lck.used = true

proc wakeupNext(lck: LockAsync) =
  if lck.waiters.len == 0:
    return
  proc wakeup =
    if lck.waiters.len > 0:
      let f = lck.waiters.popLast()
      if not f.finished:
        f.complete()
  untrackExceptions:
    callSoon wakeup

proc release(lck: LockAsync) {.raises: [LockClosedError].} =
  doAssert lck.used
  if lck.isClosed:
    raise newLockClosedError()
  lck.used = false
  wakeupNext lck

template withLock*(lck: LockAsync, body: untyped): untyped =
  await lck.acquire()
  try:
    body
  finally:
    lck.release()

func isClosed*(lck: LockAsync): bool {.raises: [].} =
  lck.isClosed

proc failSoon(f: Future[void]) =
  proc wakeup =
    if not f.finished:
      f.fail newLockClosedError()
  untrackExceptions:
    callSoon wakeup

proc close*(lck: LockAsync) {.raises: [].}  =
  if lck.isClosed:
    return
  lck.isClosed = true
  while lck.waiters.len > 0:
    failSoon lck.waiters.popLast()

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
      var puts = newSeq[int]()
      proc release() {.async.} =
        doAssert puts.len == 0
        lck.release()
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
