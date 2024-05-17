## HTTP/2 client
## WIP

when not defined(ssl):
  {.error: "this lib needs -d:ssl".}

import std/exitprocs
import std/net
import std/asyncdispatch
import std/asyncnet

import ./clientserver
import ./errors
import ./utils

when defined(hyperxTest):
  import ./testsocket

export
  withClient,
  withStream,
  newClientStream,
  recvHeaders,
  recvEnded,
  recvBody,
  #sendHeaders,
  sendBody,
  ClientStream,
  ClientContext,
  HyperxConnError,
  HyperxStrmError,
  HyperxError

var sslContext {.threadvar.}: SslContext

proc destroySslContext() {.noconv.} =
  sslContext.destroyContext()

proc defaultSslContext(): SslContext {.raises: [HyperxConnError].} =
  if not sslContext.isNil:
    return sslContext
  sslContext = defaultSslContext(ctClient)
  addExitProc(destroySslContext)
  return sslContext

when not defined(hyperxTest):
  proc newMySocket(): MyAsyncSocket {.raises: [HyperxConnError].} =
    try:
      result = newAsyncSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, buffered = true)
      wrapSocket(defaultSslContext(), result)
    except CatchableError as err:
      debugInfo err.getStackTrace()
      debugInfo err.msg
      raise newHyperxConnError(err.msg)

proc newClient*(
  hostname: string,
  port = Port 443
): ClientContext {.raises: [HyperxConnError].} =
  newClient(ctClient, newMySocket(), hostname, port)

type
  HttpMethod* = enum
    hmPost, hmGet, hmPut, hmHead, hmOptions, hmDelete, hmPatch

func `$`(hm: HttpMethod): string =
  case hm
  of hmPost: "POST"
  of hmGet: "GET"
  of hmPut: "PUT"
  of hmHead: "HEAD"
  of hmOptions: "OPTIONS"
  of hmDelete: "DELETE"
  of hmPatch: "PATCH"

const
  defaultUserAgent = "Nim - HyperX"
  defaultAccept = "*/*"
  defaultContentType = "application/json"

proc sendHeaders*(
  strm: ClientStream,
  httpMethod: HttpMethod,
  path: string,
  userAgent = defaultUserAgent,
  accept = defaultAccept,
  contentType = defaultContentType,
  contentLen = 0
) {.async.} =
  template client: untyped = strm.client
  var headers = new(seq[byte])
  headers[] = newSeq[byte]()
  client.hpackEncode(headers[], ":method", $httpMethod)
  client.hpackEncode(headers[], ":scheme", "https")
  client.hpackEncode(headers[], ":path", path)
  client.hpackEncode(headers[], ":authority", client.hostname)
  client.hpackEncode(headers[], "user-agent", userAgent)
  if httpMethod in {hmGet, hmHead}:
    doAssert contentLen == 0
    client.hpackEncode(headers[], "accept", accept)
  if httpMethod in {hmPost, hmPut, hmPatch}:
    client.hpackEncode(headers[], "content-type", contentType)
    client.hpackEncode(headers[], "content-length", $contentLen)
  let finish = contentLen == 0
  await strm.sendHeaders(headers, finish)

proc sendHeaders*(
  strm: ClientStream,
  headers: ref seq[(string, string)],
  finish: bool
) {.async.} =
  template client: untyped = strm.client
  var henc = new(seq[byte])
  henc[] = newSeq[byte]()
  for (n, v) in headers[]:
    client.hpackEncode(henc[], n, v)
  await strm.sendHeaders(henc, finish)

type
  Payload* = ref object
    s: seq[byte]
  Response* = ref object
    headers*: string
    data*: Payload

func newPayload(): Payload {.raises: [].} =
  Payload()

func newResponse*(): Response {.raises: [].} =
  Response(
    headers: "",
    data: newPayload()
  )

func text*(r: Response): string {.raises: [].} =
  result = ""
  result.add r.data.s

proc request(
  client: ClientContext,
  httpMethod: HttpMethod,
  path: string,
  data: seq[byte] = @[],
  userAgent = defaultUserAgent,
  accept = defaultAccept,
  contentType = defaultContentType
): Future[Response] {.async.} =
  result = newResponse()
  let strm = client.newClientStream()
  withStream strm:
    await strm.sendHeaders(
      httpMethod, path,
      userAgent = userAgent,
      accept = accept,
      contentType = contentType,
      contentLen = data.len
    )
    let body = new string
    body[] = ""
    if data.len > 0:
      body[].add data
      await strm.sendBody(body, finish = true)
    body[].setLen 0
    await strm.recvHeaders(body)
    result.headers.add body[]
    body[].setLen 0
    while not strm.recvEnded:
      await strm.recvBody(body)
    result.data.s.add body[]

proc get*(
  client: ClientContext,
  path: string,
  accept = defaultAccept
): Future[Response] {.async.} =
  result = await request(client, hmGet, path, accept = accept)

proc head*(
  client: ClientContext,
  path: string,
  accept = defaultAccept
): Future[Response] {.async.} =
  result = await request(client, hmHead, path, accept = accept)

proc post*(
  client: ClientContext,
  path: string,
  data: seq[byte],
  contentType = defaultContentType
): Future[Response] {.async.} =
  # https://httpwg.org/specs/rfc9113.html#n-complex-request
  result = await request(
    client, hmPost, path, data = data, contentType = contentType
  )

proc put*(
  client: ClientContext,
  path: string,
  data: seq[byte],
  contentType = defaultContentType
): Future[Response] {.async.} =
  result = await request(
    client, hmPut, path, data = data, contentType = contentType
  )

proc delete*(
  client: ClientContext,
  path: string
): Future[Response] {.async.} =
  result = await request(client, hmDelete, path)

when isMainModule:
  when not defined(hyperxTest):
    {.error: "tests need -d:hyperxTest".}

  block sock_default_state:
    var client = newClient("example.com")
    doAssert not client.sock.isConnected
    doAssert client.sock.hostname == ""
    doAssert client.sock.port == Port 0
  block sock_state:
    proc test() {.async.} =
      var client = newClient("example.com")
      withClient client:
        doAssert client.sock.isConnected
        doAssert client.sock.hostname == "example.com"
        doAssert client.sock.port == Port 443
      doAssert not client.sock.isConnected
    waitFor test()

  echo "ok"
