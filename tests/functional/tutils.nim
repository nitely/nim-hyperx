
import std/os
import std/json
import std/parseutils
import std/asyncdispatch

const localHost* = "127.0.0.1"
const localPort* = Port 8763
const localInsecurePort* = Port 7770
const testDataBaseDir = "tests/functional/"

type Header* = (string, string)

const connSpecificHeaders = [
  "connection",
  "proxy-connection",
  "keep-alive",
  "transfer-encoding",
  "upgrade"
]

func fixupHeaders(headers: seq[Header]): seq[Header] =
  result = newSeq[Header]()
  for (n, v) in headers:
    if n in connSpecificHeaders:
      continue
    if n == "te":
      continue
    result.add (n, v)

iterator stories*(theDir: string): string =
  let dir = testDataBaseDir & theDir
  for w in walkDir(dir, relative = true):
    #echo w.path
    yield dir & "/" & w.path

iterator cases*(path: string): seq[Header] =
  let jsonNode = parseJson(readFile(path))
  for cases in jsonNode["cases"]:
    var headers = newSeq[Header]()
    for nv in cases["headers"]:
      for n, v in pairs nv:
        headers.add (n, v.getStr())
    yield fixupHeaders(headers)

func isRequest*(headers: seq[Header]): bool =
  result = false
  for (n, _) in headers:
    if n == ":method":
      return true

func contentLen*(headers: seq[Header]): int =
  result = 0
  for (n, v) in headers:
    if n == "content-length":
      discard parseInt(v, result)
      return

func newStringRef*(s = ""): ref string =
  new result
  result[] = s

func rawHeaders*(headers: seq[Header]): string =
  doAssert headers.len > 0
  result = ""
  for (n, v) in headers:
    result.add n
    result.add ": "
    result.add v
    result.add "\r\n"
