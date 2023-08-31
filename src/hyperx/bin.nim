
#client
# XXX needs to be done in an unsupervised async task
proc handshake(client: ClientContextRef) {.async.} =
  # XXX see section 4 (or 3?) we can keep sending other
  #     frames as long as we don't change settings until
  #     receiving this response.
  var frm = newFrame()
  await client.read frm
  # XXX: process server setting params
  if frm.rawLen mod 6*8 != 0 or
      frm.typ != frmtSettings or
      frm.payloadLen > frmMaxPayloadSize:
    # don't send GOAWAY
    raiseError(ConnectionError, "preface error")

  frm.clear()
  frm.setTyp frmtSettings
  frm.flags.incl frmfAck
  frm.setSid frmsidMain
  await client.write frm

  frm.clear()
  await client.read frm
  doAssert frm.rawLen mod 6*8 == 0, "FRAME_SIZE_ERROR"
  doAssert frm.typ == frmtSettings
  doAssert frmfAck in frm.flags
  # XXX: make maxPayLen a dynamic per-connection setting
  if frm.payloadLen <= frmMaxPayloadSize:
    # XXX: send frame_size_error code
    raiseError(FrameSizeError, "frame size error")


#[
proc upgrade*(
  req: var Request,
  resp: var Response,
  isHttps = true
): bool {.async.} =
  ## Make OPTIONS request and
  ## upgrade to HTTP/2
  result = true
  client.avanceStreamId()
  req.add("OPTIONS * HTTP/1.1")
  req.add("Connection", "Upgrade, HTTP2-Settings")
  if isHttps:
    await req.write()
    await handshake()
  else:
    req.add("Upgrade", "h2c")
    await req.write()
    await resp.read()
    if not resp.hasStatus("101"):
      return false
    await handshake()
  #[encoded as a base64url string (that is,
   the URL- and filename-safe Base64 encoding described in Section 5 of
   [RFC4648], with any trailing '=' characters omitted).  The ABNF
   [RFC5234] production for "token68" is defined in Section 2.1 of
   [RFC7235].]#
  #req.add("HTTP2-Settings", "<base64url encoding of HTTP/2 SETTINGS payload>")

]#
