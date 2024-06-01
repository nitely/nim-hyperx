{.define: ssl.}

from std/os import getEnv
import std/deques
import std/asyncdispatch
import ../../src/hyperx/server
import ../../src/hyperx/signal
import ./tutils

const certFile = getEnv "HYPERX_TEST_CERTFILE"
const keyFile = getEnv "HYPERX_TEST_KEYFILE"

type Channel = ref object
  s: Deque[ref string]
  sig: SignalAsync

proc newChannel: Channel =
  new result
  result = Channel(
    s: initDeque[ref string](),
    sig: newSignal()
  )

proc wait(ch: Channel) {.async.} =
  if ch.s.len > 0:
    return
  try:
    await ch.sig.waitFor()
  except SignalClosedError:
    discard

proc add(ch: Channel, data: ref string) =
  ch.s.addFirst(data)
  ch.sig.trigger()

proc ended(ch: Channel): bool =
  result = ch.sig.isClosed and ch.s.len == 0

proc send(strm: ClientStream, channel: Channel) {.async.} =
  await strm.sendHeaders(
    newSeqRef(@[(":status", "200")]),
    finish = channel.ended
  )
  while not channel.ended:
    await channel.wait()
    while channel.s.len > 0:
      let data = channel.s.popLast()
      await strm.sendBody(data, finish = channel.ended)

proc recv(strm: ClientStream, channel: Channel) {.async.} =
  let data = newStringRef()
  await strm.recvHeaders(data)
  channel.add(data)
  while not strm.recvEnded:
    let data = newStringRef()
    await strm.recvBody(data)
    channel.add(data)
  channel.sig.close()

proc processStream(strm: ClientStream) {.async.} =
  withStream strm:
    let channel = newChannel()
    let sendFut = strm.send(channel)
    let recvFut = strm.recv(channel)
    await sendFut
    await recvFut
  #GC_fullCollect()

proc processStreamHandler(strm: ClientStream) {.async.} =
  try:
    await processStream(strm)
  except HyperxStrmError as err:
    debugEcho err.msg
  except HyperxConnError as err:
    debugEcho err.msg

proc processClient(client: ClientContext) {.async.} =
  withClient client:
    while client.isConnected:
      let strm = await client.recvStream()
      asyncCheck processStreamHandler(strm)

proc processClientHandler(client: ClientContext) {.async.} =
  try:
    await processClient(client)
  except HyperxConnError as err:
    debugEcho err.msg
  when defined(hyperxStats):
    echoStats client

proc serve(server: ServerContext) {.async.} =
  withServer server:
    while server.isConnected:
      let client = await server.recvClient()
      asyncCheck processClientHandler(client)

proc newServer(): ServerContext =
  newServer(
    localHost, localPort, certFile, keyFile
  )

when isMainModule:
  proc main() {.async.} =
    echo "Serving forever"
    var server = newServer()
    await server.serve()
  waitFor main()
  doAssert not hasPendingOperations()
  echo "ok"
