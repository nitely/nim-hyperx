import std/exitprocs

var mainThreadId = getThreadId()

proc atExitCall*(cl: proc () {.noconv.}) {.gcsafe, raises: [].} =
  ## addExitProc(cl) but only if it's the main thread
  if getThreadId() == mainThreadId:
    # this should be gcsafe given we only run it on the main thread
    {.cast(gcsafe).}:
      addExitProc(cl)
