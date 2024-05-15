
from std/strutils import parseHexStr
import std/os
import std/json

const testDataBaseDir = "tests/functional/"

iterator stories*(dir): string =
  let dir = testDataBaseDir & theDir
  for w in walkDir(dir, relative = true):
    #echo w.path
    for fname in w.path:
      yield dir & "/" & fname

iterator cases*(path: string): seq[tuple[string, string]] =
  let jsonNode = parseJson(readFile(path))
  for cases in jsonNode["cases"]:
    var headers = newSeq[tuple[string, string]]()
    for nv in cases["headers"]:
      for n, v in pairs nv:
        headers.add (n, v.getStr())
    yield headers

func newStringRef*(s = ""): ref string =
  new result
  result[] = s

func rawHeaders(headers: seq[tuple[string, string]]): string =
  result = ""
  for (n, v) in headers:
    result.add n
    result.add ": "
    result.add v
    result.add "\r\n"
