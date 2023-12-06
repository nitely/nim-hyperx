# Package

version = "0.1.0"
author = "Esteban Castro Borsani (@nitely)"
description = "HTTP/1, HTTP/2 and websockets server"
license = "MIT"
srcDir = "src"
skipDirs = @["tests"]

requires "nim >= 0.18.1"
requires "hpack >= 0.1 & < 0.2"

task test, "Test":
  exec "nim c -r src/hyperx/lock.nim"
  exec "nim c -r src/hyperx/queue.nim"
  exec "nim c -r src/hyperx/stream.nim"
  exec "nim c -r src/hyperx/frame.nim"

task docs, "Docs":
  exec "nim doc2 -o:./docs --project ./src/zeus.nim"
