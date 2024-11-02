import std/asyncdispatch

import ./signal
import ./errors

type
  ValueAsyncClosedError* = QueueClosedError

func newValueAsyncClosedError(): ref ValueAsyncClosedError {.raises: [].} =
  result = (ref ValueAsyncClosedError)(msg: "ValueAsync is closed")

type
  ValueAsync*[T] = ref object
    sig: SignalAsync
    val: T
    isClosed: bool

func newValueAsync*[T](): ValueAsync[T] {.raises: [].} =
  ValueAsync[T](
    sig: newSignal(),
    val: nil,
    isClosed: false
  )

proc put*[T](vala: ValueAsync[T], val: T) {.async.} =
  if vala.isClosed:
    raise newValueAsyncClosedError()
  try:
    while vala.val != nil:
      await vala.sig.waitFor()
    vala.val = val
    vala.sig.trigger()
    while vala.val != nil:
      await vala.sig.waitFor()
  except SignalClosedError:
    raise newValueAsyncClosedError()

proc get*[T](vala: ValueAsync[T]): Future[T] {.async.} =
  if vala.isClosed:
    raise newValueAsyncClosedError()
  try:
    while vala.val == nil:
      await vala.sig.waitFor()
    result = vala.val
    vala.val = nil
    vala.sig.trigger()
  except SignalClosedError:
    raise newValueAsyncClosedError()

#proc getDone*[T](vala: ValueAsync[T]) =
#  vala.val = nil
#  try:
#    vala.sig.trigger()
#  except SignalClosedError:
#    raise newValueAsyncClosedError()

proc close*[T](vala: ValueAsync[T]) {.raises: [].} =
  if vala.isClosed:
    return
  vala.isClosed = true
  vala.sig.close()

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
