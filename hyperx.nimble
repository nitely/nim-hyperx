# Package

version = "0.1.24"
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
  # integration tests
  exec "nim c -r -f tests/testclientserver.nim"

task testexamples, "Test examples":
  exec "nim c -r -f -d:hyperxSanityCheck examples/streamClient.nim"
  exec "nim c -r -f -d:hyperxSanityCheck -d:release examples/dataStream.nim"

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

task serve, "Serve":
  exec "nim c -r examples/localServer.nim"

task serve2, "Serve":
  exec "nim c -r -d:release examples/localServer.nim"

task funcserve, "Func Serve":
  exec "nim c -r -d:release -d:hyperxMaxConcurrentStrms=1000000 tests/functional/tserver.nim"

task functest, "Func test":
  exec "nim c -r tests/functional/tserial.nim"
  exec "nim c -r -d:release tests/functional/tserial.nim"
  exec "nim c -r -d:release tests/functional/tconcurrent.nim"
  exec "nim c -r -d:release tests/functional/tconcurrentdata.nim"
  exec "nim c -r -d:release tests/functional/tflowcontrol.nim"

task h2spec, "h2spec test":
  exec "./h2spec --tls --port 8783 --strict"

task h2load, "h2load test":
  exec "h2load -n100000 -c100 -m10 https://127.0.0.1:8783 | grep \"100000 2xx\""

task h2load2, "h2load test":
  exec "h2load -n100000 -c10 -m1000 -t2 https://127.0.0.1:8783"

task docs, "Docs":
  exec "nim doc2 -o:./docs --project ./src/hyperx.nim"
