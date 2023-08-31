# HyperX

> Warning: Do not use. This lib is just a toy, and it may
  never be finished. If you are working on an Http2 implementation,
  do not get discourage by this one. Just let me know, I'm ok
  with making this repo private ;)

Pure Nim Http2 client/server implementation.

## Compatibility

> Latest Nim only

## Client

```nim
import hyperx

func httpGet(client: ClientContext): string {.async.} =
  let r = await client.get("/?q=hello+world")
  assert r.statusCode == 200
  assert r.headers["content-type"] == "qwe"
  assert r.text == "asd"
  return r.text

var client = initClient("google.com")
withConnection(client):
  var tasks = newSeq[Future]()
  for i in 0 .. 9:
    tasks.add httpGet(client)
  await all(tasks)
```

## LICENSE

MIT
