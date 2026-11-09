## BE-11: a crash still answers the one envelope, and mummy's own lines are
## structured.
##
## The guard is exercised through a real socket, because the response is the
## assertion: a `Defect` must produce `application/problem+json` with
## `code = INTERNAL` and the request id of the request.

import std/[json, os, strutils, unittest]
import mummy
import db/db
import ../../src/app
import ../../src/server
import ../http_support

let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)

type
  ServeArgs = object
    server: Server
    port: Port

proc serveThread(args: ServeArgs) {.thread.} =
  try:
    args.server.serve(args.port, "127.0.0.1")
  except MummyError:
    discard

proc defectHandler(): RequestHandler =
  ## The route chain minus the routing: the same `guarded` the real `route`
  ## wraps around `dispatch`, with the handler raising what a bad slice raises.
  result = proc(request: Request) {.gcsafe.} =
    {.cast(gcsafe).}:
      beginRequest()
      guarded(request, proc() =
        raise newException(IndexDefect, "slice 0 .. 3 of a 0-length string"))

var
  database: Db

proc bootstrap() =
  database = openDb(dsn(), 1)
  install(newTestApp(database))
  let server = newServer(defectHandler(), workerThreads = 2,
    logHandler = structuredLogHandler)
  var thread: Thread[ServeArgs]
  createThread(thread, serveThread, ServeArgs(server: server, port: port))
  var up = false
  for _ in 0 ..< 200:
    try:
      let client = newHttpClient(timeout = 1000)
      defer: client.close()
      if client.get(baseUrl & "/healthz").code.int == 500:
        up = true
        break
    except CatchableError:
      discard
    sleep(50)
  doAssert up, "defect handler did not start on port " & $uint16(port)

if dsn().len == 0:
  echo "SKIP internal envelope (MAJADU_PG_DSN is not set)"
else:
  bootstrap()
  suite "a defect answers the shared envelope":
    test "the body is problem+json with code INTERNAL and a request id":
      let response = call(baseUrl, HttpGet, "/boom")
      expectStatus(response, 500)
      check header(response, "Content-Type").startsWith("application/problem+json")
      let body = parseJson(response.body)
      check body["code"].getStr() == "INTERNAL"
      check body["status"].getInt() == 500
      check body["detail"].getStr().len > 0
      check body["request_id"].getStr().len == 36

    test "the response is counted, so a crash is not invisible in the metrics":
      let before = metricsText().len
      discard call(baseUrl, HttpGet, "/boom")
      let text = metricsText()
      check text.len >= before
      check text.contains("""status="500"}""")

    test "mummy's own lines render as the same JSON object":
      let line = renderServerLog(mummy.ErrorLevel,
        ["Dropped connection, body too long"])
      let parsed = parseJson(line)
      check parsed["level"].getStr() == "error"
      check parsed["msg"].getStr() == "server"
      check parsed["detail"].getStr().contains("body too long")
      check parsed.hasKey("request_id")
      check parsed.hasKey("ts")

    test "a line from mummy is redacted like an application line":
      let line = renderServerLog(mummy.ErrorLevel,
        ["path /s/abcdef dropped"])
      check line.contains("/s/{code}")
      check not line.contains("abcdef")

  database.close()
