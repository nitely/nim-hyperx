import std/asyncdispatch

import ./signal
import ./errors

type
  ValueAsyncClosedError* = QueueClosedError

func newValueAsyncClosedError(): ref ValueAsyncClosedError {.raises: [].} =
  result = (ref ValueAsyncClosedError)(msg: "ValueAsync is closed")

type
  ValueAsync*[T] = ref object
    sigPut, sigGet: SignalAsync
    val: T
    isClosed: bool

func newValueAsync*[T](): ValueAsync[T] {.raises: [].} =
  ValueAsync[T](
    sigPut: newSignal(),
    sigGet: newSignal(),
    val: nil,
    isClosed: false
  )

proc put*[T](vala: ValueAsync[T], val: T) {.async.} =
  if vala.isClosed:
    raise newValueAsyncClosedError()
  try:
    while vala.val != nil:
      await vala.sigPut.waitFor()
    vala.val = val
    vala.sigGet.trigger()
    while vala.val != nil:
      await vala.sigPut.waitFor()
  except SignalClosedError:
    raise newValueAsyncClosedError()

proc get*[T](vala: ValueAsync[T]): Future[T] {.async.} =
  if vala.isClosed:
    raise newValueAsyncClosedError()
  try:
    while vala.val == nil:
      await vala.sigGet.waitFor()
  except SignalClosedError:
    raise newValueAsyncClosedError()
  result = vala.val

proc getDone*[T](vala: ValueAsync[T]) =
  vala.val = nil
  try:
    vala.sigPut.trigger()
  except SignalClosedError:
    raise newValueAsyncClosedError()

proc close*[T](vala: ValueAsync[T]) {.raises: [].} =
  if vala.isClosed:
    return
  vala.isClosed = true
  vala.sigPut.close()
  vala.sigGet.close()

when isMainModule:
  func newIntRef(n: int): ref int =
    new result
    result[] = n
  block:
    proc test() {.async.} =
      var q = newValueAsync[ref int]()
      proc puts {.async.} =
        await q.put newIntRef(1)
        await q.put newIntRef(2)
        await q.put newIntRef(3)
        await q.put newIntRef(4)
      let puts1 = puts()
      doAssert (await q.get())[] == 1
      doAssert (await q.get())[] == 2
      doAssert (await q.get())[] == 3
      doAssert (await q.get())[] == 4
      await puts1
    waitFor test()
    doAssert not hasPendingOperations()
  echo "ok"
