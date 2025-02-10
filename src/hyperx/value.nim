import std/asyncdispatch

import ./utils
import ./errors

template fut[T](f: FutureVar[T]): Future[T] = Future[T](f)

type
  ValueAsyncClosedError* = QueueClosedError

func newValueAsyncClosedError(): ref ValueAsyncClosedError {.raises: [].} =
  result = (ref ValueAsyncClosedError)(msg: "ValueAsync is closed")

type
  ValueAsync*[T] = ref object
    putWaiter, getWaiter: FutureVar[void]
    val: T
    isClosed: bool

func newValueAsync*[T](): ValueAsync[T] {.raises: [].} =
  {.cast(noSideEffect).}:
    let putWaiter = newFutureVar[void]()
    let getWaiter = newFutureVar[void]()
    uncatch putWaiter.complete()
    uncatch getWaiter.complete()
  result = ValueAsync[T](
    putWaiter: putWaiter,
    getWaiter: getWaiter,
    val: nil,
    isClosed: false
  )

proc wakeupSoon(f: Future[void]) {.raises: [].} =
  if not f.finished:
    uncatch f.complete()

proc put*[T](vala: ValueAsync[T], val: T) {.async.} =
  check not vala.isClosed, newValueAsyncClosedError()
  doAssert val != nil
  doAssert vala.val == nil
  vala.val = val
  wakeupSoon vala.getWaiter.fut
  doAssert vala.putWaiter.finished
  vala.putWaiter.clean()
  await vala.putWaiter.fut
  doAssert vala.val == nil

proc get*[T](vala: ValueAsync[T]): Future[T] {.async.} =
  check not vala.isClosed, newValueAsyncClosedError()
  doAssert vala.getWaiter.finished
  if vala.val == nil:
    vala.getWaiter.clean()
    await vala.getWaiter.fut
  doAssert vala.val != nil
  result = vala.val
  vala.val = nil

proc getDone*[T](vala: ValueAsync[T]) {.raises: [].} =
  wakeupSoon vala.putWaiter

proc failSoon(f: Future[void]) {.raises: [].} =
  if not f.finished:
    uncatch f.fail newValueAsyncClosedError()

proc close*[T](vala: ValueAsync[T]) {.raises: [].} =
  if vala.isClosed:
    return
  vala.isClosed = true
  failSoon vala.putWaiter.fut
  failSoon vala.getWaiter.fut

func isClosed*[T](vala: ValueAsync[T]): bool {.raises: [].} =
  vala.isClosed

when isMainModule:
  discard getGlobalDispatcher()
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
      q.getDone()
      doAssert (await q.get())[] == 2
      q.getDone()
      doAssert (await q.get())[] == 3
      q.getDone()
      doAssert (await q.get())[] == 4
      q.getDone()
      await puts1
    waitFor test()
    doAssert not hasPendingOperations()
  block:
    proc test() {.async.} =
      var q = newValueAsync[ref int]()
      proc gets {.async.} =
        doAssert (await q.get())[] == 1
        q.getDone()
        doAssert (await q.get())[] == 2
        q.getDone()
        doAssert (await q.get())[] == 3
        q.getDone()
        doAssert (await q.get())[] == 4
        q.getDone()
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
        q.getDone()
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
