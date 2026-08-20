when defined(posix):
  {.define: ssl.}

  import std/asyncdispatch
  import std/os
  import std/posix
  import std/strutils
  import ../src/hyperx/client
  import ../src/hyperx/server

  let path = getTempDir() / ("hyperx-" & $getCurrentProcessId() & ".sock")
  discard unlink(path.cstring)

  proc test() {.async.} =
    var requestHeaders = ""
    proc processStream(strm: ClientStream) {.async.} =
      let data = new string
      await strm.recvHeaders(data)
      requestHeaders = data[]
      while not strm.recvEnded:
        data[].setLen 0
        await strm.recvBody(data)
      await strm.sendHeaders(status = 204, contentLen = 0)

    let hxServer = newServerUnix(path, 0o640.Mode)
    let serverFut = hxServer.serve(processStream)
    var info: Stat
    doAssert stat(path.cstring, info) == 0
    doAssert S_ISSOCK(info.st_mode)
    doAssert (info.st_mode and Mode(0o777)) == Mode(0o640)

    let client = newClientUnix(path)
    with client:
      let response = await client.get("/")
      doAssert ":status: 204\r\n" in response.headers

    hxServer.close()
    try:
      await serverFut
    except HyperxConnError:
      discard
    doAssert requestHeaders ==
      ":method: GET\r\n" &
      ":scheme: https\r\n" &
      ":path: /\r\n" &
      ":authority: localhost\r\n" &
      "user-agent: Nim-HyperX/0.1\r\n" &
      "accept: */*\r\n"

  waitFor test()

  var info: Stat
  doAssert lstat(path.cstring, info) != 0
  doAssert osLastError() == OSErrorCode(ENOENT)
  echo "ok"
