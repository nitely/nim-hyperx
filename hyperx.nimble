# Package

version = "0.1.0"
author = "Esteban Castro Borsani (@nitely)"
description = "Pure Nim Http2 client and server"
license = "MIT"
srcDir = "src"
skipDirs = @["tests"]

requires "nim >= 2.0.0"
#requires "hpack >= 0.2.0"
requires "https://github.com/nitely/nim-hpack#head"

task test, "Test":
  exec "nim c -r src/hyperx/utils.nim"
  exec "nim c -r src/hyperx/lock.nim"
  exec "nim c -r src/hyperx/queue.nim"
  exec "nim c -r src/hyperx/stream.nim"
  exec "nim c -r src/hyperx/frame.nim"
  exec "nim c -r -f -d:hyperxTest src/hyperx/testutils.nim"
  exec "nim c -r -f -d:hyperxTest src/hyperx/client.nim"
  exec "nim c -r -f tests/testclient.nim"

task testclient, "Test client only":
  exec "nim c -r -f tests/testclient.nim"

task untestable, "Test untesteable":
  exec "nim c -r src/hyperx/untestable.nim"

task docs, "Docs":
  exec "nim doc2 -o:./docs --project ./src/hyperx.nim"
