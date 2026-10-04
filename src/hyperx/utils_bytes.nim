## Byte buffer helpers; no imports so any module can use them

template setLenUninit2*(s, newlen: untyped): untyped =
  when (NimMajor, NimMinor, NimPatch) >= (2, 2, 10):
    setLenUninit(s, newlen)
  else:
    setLen(s, newlen)

func add2*(s: var seq[byte], x: openArray[byte]) {.inline, raises: [].} =
  ## Faster than system's add, which copies byte by byte
  if x.len > 0:
    let L = s.len
    s.setLenUninit2(L+x.len)
    copyMem(addr s[L], addr x[0], x.len)
