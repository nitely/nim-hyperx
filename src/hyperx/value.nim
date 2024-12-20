import std/asyncdispatch

import ./utils
import ./errors

type
  ValueAsyncClosedError* = QueueClosedError

func newValueAsyncClosedError(): ref ValueAsyncClosedError {.raises: [].} =
  result = (ref ValueAsyncClosedError)(msg: "ValueAsync is closed")

type
  ValueAsync*[T] = ref object
    putWaiter, getWaiter: Future[void]
    val: T
    isClosed: bool

func newValueAsync*[T](): ValueAsync[T] {.raises: [].} =
  ValueAsync[T](
    putWaiter: nil,
    getWaiter: nil,
    val: nil,
    isClosed: false
  )

proc wakeupSoon(f: Future[void]) {.raises: [].} =
  if f == nil:
    return
  if f.finished:
    return
  proc wakeup =
    if not f.finished:
      f.complete()
  untrackExceptions:
    callSoon wakeup

proc put*[T](vala: ValueAsync[T], val: T) {.async.} =
  check not vala.isClosed, newValueAsyncClosedError()
  doAssert val != nil
  doAssert vala.val == nil
  vala.val = val
  wakeupSoon vala.getWaiter
  doAssert vala.putWaiter == nil or vala.putWaiter.finished
  vala.putWaiter = newFuture[void]()
  await vala.putWaiter
  doAssert vala.val == nil

proc get*[T](vala: ValueAsync[T]): Future[T] {.async.} =
  check not vala.isClosed, newValueAsyncClosedError()
  doAssert vala.getWaiter == nil or vala.getWaiter.finished
  if vala.val == nil:
    vala.getWaiter = newFuture[void]()
    await vala.getWaiter
  doAssert vala.val != nil
  result = vala.val
  vala.val = nil
  wakeupSoon vala.putWaiter

proc failSoon(f: Future[void]) {.raises: [].} =
  if f == nil:
    return
  if f.finished:
    return
  proc wakeup =
    if not f.finished:
      f.fail newValueAsyncClosedError()
  untrackExceptions:
    callSoon wakeup

proc close*[T](vala: ValueAsync[T]) {.raises: [].} =
  if vala.isClosed:
    return
  vala.isClosed = true
  failSoon vala.putWaiter
  failSoon vala.getWaiter

when isMainModule:
  func newIntRef(n: int): ref int =
    new result
    result[] = n
  block:
    proc test() {.async.} =
      var q = newValueAsync[ref int]()
      proc puts {.async.} =
        await q.put newIntRef(1)
        doAssert q.val == nil
        await q.put newIntRef(2)
        doAssert q.val == nil
        await q.put newIntRef(3)
        doAssert q.val == nil
        await q.put newIntRef(4)
        doAssert q.val == nil
      let puts1 = puts()
      doAssert (await q.get())[] == 1
      doAssert (await q.get())[] == 2
      doAssert (await q.get())[] == 3
      doAssert (await q.get())[] == 4
      await puts1
    waitFor test()
    doAssert not hasPendingOperations()
  block:
    proc test() {.async.} =
      var q = newValueAsync[ref int]()
      proc gets {.async.} =
        doAssert (await q.get())[] == 1
        doAssert (await q.get())[] == 2
        doAssert (await q.get())[] == 3
        doAssert (await q.get())[] == 4
      let gets1 = gets()
      await q.put newIntRef(1)
      doAssert q.val == nil
      await q.put newIntRef(2)
      doAssert q.val == nil
      await q.put newIntRef(3)
      doAssert q.val == nil
      await q.put newIntRef(4)
      doAssert q.val == nil
      await gets1
    waitFor test()
    doAssert not hasPendingOperations()
  block:
    proc test() {.async.} =
      var q = newValueAsync[ref int]()
      proc gets {.async.} =
        doAssert (await q.get())[] == 1
        q.close()
      let gets1 = gets()
      await q.put newIntRef(1)
      try:
        await q.put newIntRef(2)
        doAssert false
      except QueueClosedError:
        discard
      await gets1
    waitFor test()
    doAssert not hasPendingOperations()
  echo "ok"
