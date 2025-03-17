{.define: ssl.}
{.define: hyperxTest.}
{.define: hyperxSanityCheck.}

import std/strutils
import std/asyncdispatch
import ../src/hyperx/server
import ../src/hyperx/testutils
import ../src/hyperx/frame
import ../src/hyperx/errors
from ../src/hyperx/clientserver import
  stgWindowSize,
  stgInitialWindowSize,
  stgInitialMaxFrameSize,
  stgMaxSettingsList

func toBytes(s: string): seq[byte] =
  result = newSeq[byte]()
  for c in s:
    result.add c.byte

func toString(s: openArray[byte]): string =
  result = ""
  for c in s:
    result.add c.char

func newStringRef(s = ""): ref string =
  new result
  result[] = s

const
  preface = "PRI * HTTP/2.0\r\L\r\LSM\r\L\r\L".toBytes
  headers =
    ":method: GET\r\n" &
    ":path: /\r\n" &
    ":scheme: https\r\n" &
    "foo: foo\r\n"

proc checkHandshake(tc: TestClientContext) {.async.} =
  let frm1 = await tc.sent()
  doAssert frm1.typ == frmtSettings
  doAssert frm1.sid == frmSidMain
  if stgWindowSize > stgInitialWindowSize:
    let frm2 = await tc.sent()
    doAssert frm2.typ == frmtWindowUpdate
    doAssert frm2.sid == frmSidMain

testAsync "simple request":
  var checked = false
  const text = "0123456789"
  var server = newServer(
    "foo.bar", Port 443, "./cert", "./key"
  )
  with server:
    let client1 = await server.recvClient()
    let tc1 = newTestClient(client1)
    await tc1.recv(preface)
    with tc1.client:
      await tc1.checkHandshake()
      await tc1.recv(headers)
      let strm = await client1.recvStream()
      with strm:
        var data = newStringRef()
        await strm.recvHeaders(data)
        doAssert data[] == headers
        doAssert strm.recvEnded
        await strm.sendHeaders(
          status = 200,
          contentType = "text/plain",
          contentLen = text.len
        )
        await strm.sendBody(newStringRef(text), finish = true)
      let frm1 = await tc1.sent()
      doAssert frm1.sid.int == 1
      doAssert frm1.typ == frmtHeaders
      doAssert frm1.payload.toString ==
        ":status: 200\r\L" &
        "content-type: text/plain\r\L" &
        "content-length: 10\r\L"
      doAssert frmfEndStream notin frm1.flags
      let frm2 = await tc1.sent()
      doAssert frm2.sid.int == 1
      doAssert frm2.typ == frmtData
      doAssert frm2.payload.toString == text
      doAssert frmfEndStream in frm2.flags
      checked = true
  doAssert checked

testAsync "exceed window size":
  var check1 = false
  var check2 = false
  var server = newServer(
    "foo.bar", Port 443, "./cert", "./key"
  )
  proc sender(tc: TestClientContext) {.async.} =
    tc.sid += 2
    let strmId = tc.sid
    await tc.recv(headers, strmId, finish = false)
    var text = ""
    for _ in 0 .. stgInitialMaxFrameSize.int-1:
      text.add 'a'
    var frmData1 = frame(frmtData, strmId.FrmSid)
    frmData1.add text.toBytes
    var sentCount = 0
    while sentCount <= stgWindowSize.int * 2:
      if not tc.client.isConnected:  # errored out
        break
      await tc.recv frmData1.s
      sentCount += text.len
    var i = 0
    while tc.client.isConnected:
      await sleepCycle()
      inc i
      doAssert i < 1000

  with server:
    let client1 = await server.recvClient()
    let tc1 = newTestClient(client1)
    await tc1.recv(preface)
    with tc1.client:
      await tc1.checkHandshake()
      let senderFut = tc1.sender()
      let strm = await client1.recvStream()
      try:
        with strm:
          await senderFut
          var data = newStringRef()
          await strm.recvHeaders(data)
          var consumed = 0
          try:
            while not strm.recvEnded:
              data[].setLen 0
              await strm.recvBody(data)
              consumed += data[].len
            doAssert false
          except HyperxConnError as err:
            doAssert "FLOW_CONTROL_ERROR" in err.msg
            # make sure we consume all pending data?
            #doAssert consumed == stgWindowSize.int
            check1 = true
            raise err
        doAssert false
      except HyperxConnError as err:
        doAssert "FLOW_CONTROL_ERROR" in err.msg
        check2 = true
  doAssert check1
  doAssert check2

testAsync "consume window size":
  var check1 = false
  var server = newServer(
    "foo.bar", Port 443, "./cert", "./key"
  )
  proc sender(tc: TestClientContext) {.async.} =
    tc.sid += 2
    let strmId = tc.sid
    await tc.recv(headers, strmId, finish = false)
    var text = ""
    for _ in 0 .. frmsMaxFrameSize.int-1:
      text.add 'a'
    var frmData1 = frame(frmtData, strmId.FrmSid)
    frmData1.add text.toBytes
    var sentCount = 0
    while true:
      if sentCount+text.len > stgWindowSize.int:
        break
      doAssert tc.client.isConnected
      await tc.recv frmData1.s
      sentCount += text.len
    doAssert sentCount <= stgWindowSize.int
    let frmEnd = frame(frmtData, strmId.FrmSid, @[frmfEndStream])
    frmEnd.add toOpenArray(text.toBytes, 0, stgWindowSize.int-sentCount-1)
    await tc.recv frmEnd.s

  with server:
    let client1 = await server.recvClient()
    let tc1 = newTestClient(client1)
    await tc1.recv(preface)
    with tc1.client:
      await tc1.checkHandshake()
      let senderFut = tc1.sender()
      let strm = await client1.recvStream()
      with strm:
        await senderFut
        var data = newStringRef()
        await strm.recvHeaders(data)
        var consumed = 0
        while not strm.recvEnded:
          data[].setLen 0
          await strm.recvBody(data)
          consumed += data[].len
        doAssert consumed == stgWindowSize.int
        await strm.sendHeaders(
          status = 200,
          contentType = "text/plain",
          contentLen = 0
        )
        check1 = true
  doAssert check1

testAsync "do not exceed settings list":
  var checked = false
  var server = newServer(
    "foo.bar", Port 443, "./cert", "./key"
  )
  with server:
    let client1 = await server.recvClient()
    let tc1 = newTestClient(client1)
    await tc1.recv(preface)
    with tc1.client:
      await tc1.checkHandshake()
      var frmSetting = frame(frmtSettings, frmSidMain)
      for _ in 0 .. stgMaxSettingsList.int-1:
        frmSetting.addSetting(0x16.FrmSetting, 1000.uint32)
      await tc1.recv frmSetting.s
      await tc1.recv headers
      discard await client1.recvStream()
      checked = true
  doAssert checked

testAsync "exceed settings list":
  var checked = false
  var server = newServer(
    "foo.bar", Port 443, "./cert", "./key"
  )
  with server:
    let client1 = await server.recvClient()
    let tc1 = newTestClient(client1)
    await tc1.recv(preface)
    with tc1.client:
      await tc1.checkHandshake()
      var frmSetting = frame(frmtSettings, frmSidMain)
      for _ in 0 .. stgMaxSettingsList.int+1:
        frmSetting.addSetting(0x09.FrmSetting, 1000.uint32)
      await tc1.recv frmSetting.s
      try:
        discard await client1.recvStream()
        doAssert false
      except HyperxConnError:
        checked = true
  doAssert checked
