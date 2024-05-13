# Package

version = "0.1.12"
author = "Esteban Castro Borsani (@nitely)"
description = "Pure Nim Http2 client and server"
license = "MIT"
srcDir = "src"
skipDirs = @["tests", "examples"]

requires "nim >= 2.0.0"
requires "hpack >= 0.4.0"

task test, "Test":
  exec "nim c -r src/hyperx/utils.nim"
  exec "nim c -r src/hyperx/queue.nim"
  exec "nim c -r src/hyperx/signal.nim"
  exec "nim c -r src/hyperx/stream.nim"
  exec "nim c -r src/hyperx/frame.nim"
  exec "nim c -r -f -d:hyperxTest -d:ssl src/hyperx/testutils.nim"
  exec "nim c -r -f -d:hyperxTest -d:ssl src/hyperx/client.nim"
  exec "nim c -r -f -d:hyperxTest -d:ssl src/hyperx/server.nim"
  exec "nim c -r -f -d:hyperxTest -d:ssl src/hyperx/clientserver.nim"
  exec "nim c -r -f tests/testclient.nim"
  exec "nim c -r -f tests/testserver.nim"
  exec "nim c -r -f tests/testclientserver.nim"
  exec "nim c -r -f examples/streamClient.nim"

task testclient, "Test client only":
  exec "nim c -r -f tests/testclient.nim"

task untestable, "Test untesteable":
  exec "nim c -r examples/simpleQueries.nim"
  exec "nim c -r examples/multipleGets.nim"

task testclientserver, "Test client server":
  exec "nim c -r -f tests/testclientserver.nim"

task test2, "Test2":
  exec "nim c -r -f tests/testclient.nim"
  exec "nim c -r -f tests/testserver.nim"
  exec "nim c -r -f tests/testclientserver.nim"
  exec "nim c -r -f examples/streamClient.nim"

task serve, "Serve":
  exec "nim c -r examples/localServer.nim"

task serve2, "Serve":
  exec "nim c -r -d:release examples/localServer.nim"

task docs, "Docs":
  exec "nim doc2 -o:./docs --project ./src/hyperx.nim"
