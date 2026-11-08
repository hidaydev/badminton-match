## Record and replay against a local stub (TL-09).
##
## Nothing here talks to the real API or to the recorded corpora: the stub is a
## mummy server on an ephemeral port that answers the handful of routes these
## cases name, and every corpus lives in a temporary directory. The point of
## the suite is the comparator: a stub that answers a different body must make
## `replay` fail, not only a stub that agrees with the case.

import std/[exitprocs, json, net, os, osproc, strtabs, strutils, unittest]
import mummy

import ../main

# `send` and `recordOne` end the process on a bad verb or a spec row without a
# route, so those two cases run in a child process that is this same binary.
const
  probeVariable = "PARITY_REPLAY_PROBE"
  baseVariable = "PARITY_REPLAY_BASE"
  dirVariable = "PARITY_REPLAY_DIR"

proc selfRun(args: seq[string]; probe = "";
             extra: seq[(string, string)] = @[]):
    tuple[output: string, exitCode: int] =
  var environment = newStringTable(modeCaseSensitive)
  for (key, item) in envPairs():
    environment[key] = item
  environment[probeVariable] = probe
  for (key, value) in extra:
    environment[key] = value
  var binary = getAppFilename()
  if not binary.isAbsolute:
    binary = getCurrentDir() / binary
  var command = quoteShell(binary)
  for argument in args:
    command.add " " & quoteShell(argument)
  execCmdEx(command, env = environment)

when isMainModule:
  case getEnv(probeVariable)
  of "main":
    main()
    quit(0)
  of "send-unsupported":
    discard send("http://127.0.0.1:1", "TRACE", "/healthz", "", @[])
    quit(0)
  of "record-no-route":
    recordOne(Options(base: getEnv(baseVariable), dir: getEnv(dirVariable),
      name: "no-route", path: "/healthz", spec: "cases.tsv"))
    quit(0)
  else:
    discard

# The stub answers a fixed set of routes so the handler stays stateless and
# `{.gcsafe.}` without a lock. `/echo` reports what it received, which is how
# the client-side headers are asserted.

proc answer(request: Request) {.gcsafe.} =
  case request.path
  of "/healthz":
    request.respond(200, @[("Content-Type", "application/json")],
      """{"status":"ok"}""")
  of "/other":
    request.respond(200, @[("Content-Type", "application/json")],
      """{"status":"changed"}""")
  of "/created":
    request.respond(201, @[("Content-Type", "application/json")],
      """{"id":1}""")
  of "/empty":
    request.respond(204, @[], "")
  of "/plain":
    request.respond(200, @[("Content-Type", "text/plain")],
      "uptime 1234 seconds")
  of "/echo":
    let document = %*{
      "method": request.httpMethod,
      "path": request.path,
      "contentType": request.headers["Content-Type"],
      "acceptEncoding": request.headers["Accept-Encoding"],
      "body": request.body,
    }
    request.respond(200, @[("Content-Type", "application/json")], $document)
  else:
    request.respond(404, @[("Content-Type", "application/json")],
      """{"code":"notFound","i18nKey":"error.notFound","status":404}""")

type
  StubArgs = object
    server: Server
    port: Port

proc serveStub(args: StubArgs) {.thread.} =
  try:
    args.server.serve(args.port, "127.0.0.1")
  except MummyError:
    discard

proc freePort(): Port =
  ## The kernel picks the port, so two suites running side by side cannot
  ## collide on a hardcoded number.
  let probe = newSocket()
  probe.setSockOpt(OptReuseAddr, true)
  probe.bindAddr(Port(0), "127.0.0.1")
  let (_, port) = probe.getLocalAddr()
  probe.close()
  port

var
  stubServer: Server
  stubThread: Thread[StubArgs]
  stubPort: Port
  stubStarted = false

proc stubBase(): string =
  ## One server for the whole file, started on first use. The process exit ends
  ## it; nothing after the last suite reads it.
  if not stubStarted:
    stubPort = freePort()
    stubServer = newServer(answer, workerThreads = 1)
    createThread(stubThread, serveStub, StubArgs(server: stubServer,
      port: stubPort))
    var ready = false
    for _ in 0 ..< 50:
      try:
        let probe = newSocket()
        probe.connect("127.0.0.1", stubPort)
        probe.close()
        ready = true
        break
      except CatchableError:
        sleep(100)
    if not ready:
      raise newException(IOError, "the parity stub did not start")
    stubStarted = true
  "http://127.0.0.1:" & $stubPort.int

proc tempRoot(): string =
  getTempDir() / ("parity-replay-" & $getCurrentProcessId())

proc freshDir(name: string): string =
  result = tempRoot() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc cleanupRoot() {.noconv.} =
  ## Runs at exit, so it rebuilds the name instead of reading a global.
  let root = getTempDir() / ("parity-replay-" & $getCurrentProcessId())
  try:
    if dirExists(root):
      removeDir(root)
  except CatchableError:
    discard

addExitProc(cleanupRoot)

proc caseDocument(path: string; status: int; body: JsonNode): JsonNode =
  result = %*{
    "route": "GET " & path,
    "request": {"method": "GET", "path": path},
    "expect": {"status": status, "body": body},
  }

proc writeCase(dir, name, path: string; status: int; body: JsonNode) =
  writeFile(dir / (name & ".json"),
    pretty(caseDocument(path, status, body)) & "\n")

suite "responseExpectation":
  test "a 204 stores an empty body and the emptyBody flag":
    let expected = responseExpectation(204, "")
    check expected["status"].getInt() == 204
    check expected["body"].getStr() == ""
    check expected["emptyBody"].getBool()

  test "a JSON body is normalized":
    let expected = responseExpectation(200,
      """{"b":"11111111-2222-3333-4444-555555555555","a":1}""")
    check $expected["body"] == """{"a":1,"b":"{uuid}"}"""
    check not expected.hasKey("emptyBody")

  test "a body that is not JSON is masked as plain text":
    let expected = responseExpectation(200, "uptime 1234 seconds")
    check expected["body"].getStr() == "uptime {number} seconds"

suite "send":
  test "issues the method and path and returns the status and body":
    let (status, body) = send(stubBase(), "POST", "/created", "", @[])
    check status == 201
    check body == """{"id":1}"""

  test "a body defaults the Content-Type to JSON":
    let (status, body) = send(stubBase(), "POST", "/echo", """{"a":1}""", @[])
    check status == 200
    let echoed = parseJson(body)
    check echoed["method"].getStr() == "POST"
    check echoed["path"].getStr() == "/echo"
    check echoed["contentType"].getStr() == "application/json"
    check echoed["body"].getStr() == """{"a":1}"""

  test "an explicit Content-Type is kept":
    let (_, body) = send(stubBase(), "POST", "/echo", "hello",
      @[("Content-Type", "text/plain")])
    check parseJson(body)["contentType"].getStr() == "text/plain"

  test "every request asks for an identity encoding":
    let (_, body) = send(stubBase(), "GET", "/echo", "", @[])
    check parseJson(body)["acceptEncoding"].getStr() == "identity"

  test "an empty response carries an empty body":
    let (emptyStatus, emptyBody) = send(stubBase(), "GET", "/empty", "", @[])
    check emptyStatus == 204
    check emptyBody.len == 0

  test "a plain text response is returned unchanged":
    let (status, body) = send(stubBase(), "GET", "/plain", "", @[])
    check status == 200
    check body == "uptime 1234 seconds"

  test "an unsupported verb is a failure":
    let run = selfRun(@[], probe = "send-unsupported")
    check run.exitCode == 1
    check run.output.contains("parity: unsupported method: TRACE")

suite "caseRequest":
  test "reads the current request shape":
    let node = %*{
      "request": {"method": "PATCH", "path": "/c/1", "body": "{}",
                  "headers": {"If-Match": "\"3\""}},
    }
    let stored = caseRequest(node)
    check stored.verb == "PATCH"
    check stored.path == "/c/1"
    check stored.body == "{}"
    check stored.headers == @[("If-Match", "\"3\"")]

  test "reads the T-012 top-level shape":
    let stored = caseRequest(%*{"method": "POST", "path": "/sessions"})
    check stored.verb == "POST"
    check stored.path == "/sessions"
    check stored.body.len == 0
    check stored.headers.len == 0

  test "a top-level case without a method falls back to GET":
    check caseRequest(%*{"path": "/healthz"}).verb == "GET"

suite "recordOne":
  var dir: string

  setup:
    dir = freshDir("record")

  teardown:
    if dirExists(dir):
      removeDir(dir)

  test "keeps the route of an existing case when it is not repeated":
    recordOne(Options(base: stubBase(), dir: dir, name: "kept",
      path: "/healthz", route: "GET /healthz"))
    recordOne(Options(base: stubBase(), dir: dir, name: "kept",
      path: "/healthz"))
    let document = parseFile(dir / "kept.json")
    check document["route"].getStr() == "GET /healthz"
    check document["request"]["method"].getStr() == "GET"
    check document["expect"]["status"].getInt() == 200

  test "an explicit route replaces the stored one":
    recordOne(Options(base: stubBase(), dir: dir, name: "replaced",
      path: "/healthz", route: "GET /healthz"))
    recordOne(Options(base: stubBase(), dir: dir, name: "replaced",
      path: "/healthz", route: "GET /other"))
    check parseFile(dir / "replaced.json")["route"].getStr() == "GET /other"

  test "a 204 is recorded with emptyBody":
    recordOne(Options(base: stubBase(), dir: dir, name: "empty",
      path: "/empty", route: "GET /empty"))
    let expect = parseFile(dir / "empty.json")["expect"]
    check expect["status"].getInt() == 204
    check expect["emptyBody"].getBool()

  test "a spec row without a route is refused":
    let run = selfRun(@[], probe = "record-no-route",
      extra = @[(baseVariable, stubBase()), (dirVariable, dir)])
    check run.exitCode == 1
    check run.output.contains("parity: route is required in the spec: no-route")

suite "recordSpec":
  var dir: string

  setup:
    dir = freshDir("spec")

  teardown:
    if dirExists(dir):
      removeDir(dir)

  test "records every row in order and reads the header and body fields":
    writeFile(dir / "body.txt", """{"echo":true}""")
    writeFile(dir / "cases.tsv",
      "# name\troute\tmethod\tpath\theaders\tbody\n" &
      "first\tGET /healthz\tGET\t/healthz\t-\t-\n" &
      "second\tPOST /echo\tPOST\t/echo\tContent-Type: text/plain\t@body.txt\n")
    recordSpec(Options(base: stubBase(), dir: dir, spec: dir / "cases.tsv"))
    let first = parseFile(dir / "first.json")
    check first["route"].getStr() == "GET /healthz"
    check first["request"]["path"].getStr() == "/healthz"
    let second = parseFile(dir / "second.json")
    check second["request"]["method"].getStr() == "POST"
    check second["request"]["headers"]["Content-Type"].getStr() == "text/plain"
    check second["request"]["body"].getStr() == """{"echo":true}"""

suite "replayOne":
  var dir: string

  setup:
    dir = freshDir("one")

  teardown:
    if dirExists(dir):
      removeDir(dir)

  test "a matching status and body passes":
    writeCase(dir, "ok", "/healthz", 200, %*{"status": "ok"})
    check replayOne(Options(base: stubBase(), dir: dir), "ok")

  test "a different body fails":
    writeCase(dir, "drift", "/other", 200, %*{"status": "ok"})
    check not replayOne(Options(base: stubBase(), dir: dir), "drift")

  test "a different status fails":
    writeCase(dir, "status", "/healthz", 201, %*{"status": "ok"})
    check not replayOne(Options(base: stubBase(), dir: dir), "status")

  test "a case that is not on disk fails":
    check not replayOne(Options(base: stubBase(), dir: dir), "absent")

suite "replay":
  var dir: string

  setup:
    dir = freshDir("replay")

  teardown:
    if dirExists(dir):
      removeDir(dir)

  proc writeSpec(target: string; names: seq[string]) =
    var spec = "# name\troute\tmethod\tpath\theaders\tbody\n"
    for name in names:
      spec.add name & "\tGET /healthz\tGET\t/healthz\t-\t-\n"
    writeFile(target, spec)

  test "replays in cases.tsv order when a spec is given":
    writeCase(dir, "a", "/healthz", 200, %*{"status": "ok"})
    writeCase(dir, "b", "/healthz", 200, %*{"status": "ok"})
    writeSpec(dir / "cases.tsv", @["b", "a"])
    let run = selfRun(@["replay", "--dir", dir, "--base", stubBase(),
      "--spec", dir / "cases.tsv"], probe = "main")
    check run.exitCode == 0
    check run.output.contains("parity: 2 cases ok")
    check run.output.find("parity: ok b") < run.output.find("parity: ok a")

  test "replays sorted filenames without a spec":
    writeCase(dir, "b", "/healthz", 200, %*{"status": "ok"})
    writeCase(dir, "a", "/healthz", 200, %*{"status": "ok"})
    let run = selfRun(@["replay", "--dir", dir, "--base", stubBase()],
      probe = "main")
    check run.exitCode == 0
    check run.output.find("parity: ok a") < run.output.find("parity: ok b")

  test "a different body is reported as body differs":
    writeCase(dir, "drift", "/other", 200, %*{"status": "ok"})
    let run = selfRun(@["replay", "--dir", dir, "--base", stubBase()],
      probe = "main")
    check run.exitCode == 1
    check run.output.contains("parity: body differs")
    check run.output.contains("1 of 1 cases failed")

  test "a mismatch reports the status and the body":
    writeCase(dir, "wrong", "/healthz", 404, %*{"expected": true})
    let run = selfRun(@["replay", "--dir", dir, "--base", stubBase()],
      probe = "main")
    check run.exitCode == 1
    check run.output.contains("parity: status: expected 404, got 200")
    check run.output.contains("parity: body differs")