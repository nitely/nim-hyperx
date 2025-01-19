import std/exitprocs

var mainThreadId = getThreadId()

proc atExitCall*(cl: proc () {.noconv.}): bool {.gcsafe, raises: [], discardable.} =
  ## addExitProc(cl) but only if it's the main thread
  if getThreadId() == mainThreadId:
    # this should be gcsafe given we only run it on the main thread
    {.cast(gcsafe).}:
      addExitProc(cl)
    return true
  return false

when isMainModule:
  proc noop {.noconv.} =
    discard
  block:
    atExitCall(noop)
  block:
    doAssert atExitCall(noop)
  block:
    proc worker(result: ptr bool) {.thread.} =
      result[] = atExitCall(noop)
    var t: Thread[ptr bool]
    var result = true
    createThread(t, worker, addr result)
    joinThread(t)
    doAssert not result
  echo "ok"
