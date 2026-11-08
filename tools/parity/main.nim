import std/[algorithm, httpclient, json, os, strutils, tables]
import cli
import normalizer
import state as parityState
import db/db
import hex
import share/crypto

const
  program = "parity"
  defaultDir = "testdata/parity/v1"
  defaultBase = "http://127.0.0.1:8091"

  # The v2 fixture (testdata/parity/v2/fixture.sql) fixes these ids; the share
  # link is sealed here because its ciphertext needs the real keyring.
  fixtureCommunity = "10000000-0000-4000-8000-000000000001"
  fixtureSession = "40000000-0000-4000-8000-000000000001"
  fixtureLink = "50000000-0000-4000-8000-000000000001"
  fixtureAdmin = "20000000-0000-4000-8000-000000000002"
  fixtureShareCode = "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a"

type
  Options* = object
    ## Exported for tools/parity/tests (D-5, TL-09): the record and replay
    ## cases build one by hand instead of going through the command line.
    command*, base*, dir*, name*, verb*, path*, body*, bodyFile*, route*,
      spec*, routes*, dsn*: string
    headers*: seq[(string, string)]
    names*: seq[string]

proc parseHeader(value: string): (string, string) =
  let colon = value.find(':')
  if colon <= 0:
    usageFail(program, "invalid header (expected \"Name: value\"): " & value)
  (value[0 ..< colon].strip(), value[colon + 1 .. ^1].strip())

proc parseArgs(): Options =
  result.verb = ""
  result.dir = defaultDir
  result.base = defaultBase
  if paramCount() < 1:
    usageFail(program, "usage: parity record|lint|replay|reset|state-* [options]")
  result.command = paramStr(1)
  for (flag, value) in flags(program, 2, ["--base", "--dir", "--name",
      "--method", "--path", "--body", "--body-file", "--route", "--spec",
      "--routes", "--dsn", "--header"]):
    case flag
    of "--base":
      result.base = value
    of "--dir":
      result.dir = value
    of "--name":
      result.name = value
    of "--method":
      result.verb = value
    of "--path":
      result.path = value
    of "--body":
      result.body = value
    of "--body-file":
      result.bodyFile = value
    of "--route":
      result.route = value
    of "--spec":
      result.spec = value
    of "--routes":
      result.routes = value
    of "--dsn":
      result.dsn = value
    of "--header":
      result.headers.add(parseHeader(value))
    else:
      if flag.startsWith("--"):
        usageFail(program, "unknown argument: " & flag)
      result.names.add(flag)

proc openParityDb(options: Options): Db =
  let dsn =
    if options.dsn.len > 0: options.dsn
    else: dsnOrFail(program,
      detail = "MAJADU_PG_DSN or --dsn is required for this command")
  try:
    result = openDb(dsn, 1)
  except DbError as error:
    fail(program, "cannot connect: " & error.msg)

proc casePath(dir, name: string): string = dir / (name & ".json")

proc requestBody(options: Options): string =
  if options.bodyFile.len > 0:
    if not fileExists(options.bodyFile):
      fail(program, "body file not found: " & options.bodyFile)
    result = readFile(options.bodyFile)
  else:
    result = options.body

proc send*(base, verbText, path, body: string,
           headers: seq[(string, string)]): (int, string) =
  var client = newHttpClient(timeout = 10000)
  defer: client.close()
  var requestHeaders = newHttpHeaders()
  for (key, value) in headers:
    requestHeaders[key] = value
  if body.len > 0 and not requestHeaders.hasKey("Content-Type"):
    requestHeaders["Content-Type"] = "application/json"
  # Captures must not depend on transfer-level compression.
  requestHeaders["Accept-Encoding"] = "identity"
  client.headers = requestHeaders
  var verb: HttpMethod = HttpGet
  case verbText.toUpperAscii()
  of "GET": verb = HttpGet
  of "POST": verb = HttpPost
  of "PUT": verb = HttpPut
  of "PATCH": verb = HttpPatch
  of "DELETE": verb = HttpDelete
  of "HEAD": verb = HttpHead
  of "OPTIONS": verb = HttpOptions
  else: fail(program, "unsupported method: " & verbText)
  let response = client.request(base & path, httpMethod = verb, body = body)
  (response.code.int, response.body)

proc responseExpectation*(status: int, body: string): JsonNode =
  result = newJObject()
  result["status"] = %status
  if body.len == 0:
    # A 204 carries no payload. The corpus says so explicitly so the lint can
    # tell "empty on purpose" apart from an expectation that lost its body.
    result["body"] = %""
    result["emptyBody"] = %true
  else:
    try:
      result["body"] = normalizeJson(parseJson(body))
    except JsonParsingError:
      result["body"] = %normalizePlainText(body)

proc copyExtras(document, existing: JsonNode) =
  for key in ["expectNim", "expectedDivergence"]:
    if existing.hasKey(key):
      document[key] = existing[key]

proc recordOne*(options: Options) =
  if options.name.len == 0:
    usageFail(program, "--name is required for record")
  if options.path.len == 0:
    usageFail(program, "--path is required for record")
  let verb = if options.verb.len > 0: options.verb.toUpperAscii() else: "GET"
  let body = requestBody(options)
  let (status, responseBody) = send(options.base, verb, options.path, body,
    options.headers)

  var route = options.route
  let target = casePath(options.dir, options.name)
  var existing = newJObject()
  if fileExists(target):
    try:
      existing = parseFile(target)
    except JsonParsingError:
      discard
  if route.len == 0 and existing.hasKey("route"):
    # Keep the route template of an existing case when it is not repeated.
    route = existing["route"].getStr()
  if options.spec.len > 0 and route.len == 0:
    fail(program, "route is required in the spec: " & options.name)

  var document = newJObject()
  document["route"] = %route
  var request = newJObject()
  request["method"] = %verb
  request["path"] = %options.path
  if options.headers.len > 0:
    var headerNode = newJObject()
    for (key, value) in options.headers:
      headerNode[key] = %value
    request["headers"] = headerNode
  if body.len > 0:
    request["body"] = %body
  document["request"] = request
  document["expect"] = responseExpectation(status, responseBody)
  copyExtras(document, existing)

  createDir(options.dir)
  writeFile(target, pretty(document, indent = 2) & "\n")
  echo "parity: recorded " & target & " (" & $status & ")"

proc specHeaders(field: string): seq[(string, string)] =
  ## Several headers share one TSV field, separated by `;`. A value never
  ## contains `;` in this corpus (cookies and If-Match do not).
  if field.strip() == "-":
    return @[]
  for part in field.split(';'):
    if part.strip().len > 0:
      result.add(parseHeader(part.strip()))

proc specBody(field, specDir: string): (string, string) =
  if field.strip() == "-":
    return ("", "")
  let value = field.strip()
  if value.startsWith("@"):
    return ("", specDir / value[1 .. ^1])
  (value, "")

proc recordSpec*(options: Options) =
  if not fileExists(options.spec):
    fail(program, "spec file not found: " & options.spec)
  let specDir = options.spec.parentDir
  var count = 0
  for line in readFile(options.spec).splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0 or trimmed.startsWith("#"):
      continue
    let fields = line.split('\t')
    if fields.len != 6:
      fail(program, "invalid spec line (expected 6 tab-separated fields): " & line)
    var single = options
    single.spec = ""
    single.name = fields[0].strip()
    single.route = fields[1].strip()
    single.verb = fields[2].strip()
    single.path = fields[3].strip()
    single.headers = specHeaders(fields[4])
    let (specBodyValue, specFileValue) = specBody(fields[5], specDir)
    single.body = specBodyValue
    single.bodyFile = specFileValue
    recordOne(single)
    count.inc
  echo "parity: recorded " & $count & " cases from " & options.spec

proc caseRequest*(node: JsonNode):
    tuple[verb, path, body: string, headers: seq[(string, string)]] =
  if not node.hasKey("request") or node["request"].kind != JObject:
    # T-012 cases stored method/path at the top level.
    result.verb = if node.hasKey("method"): node["method"].getStr() else: "GET"
    result.path = if node.hasKey("path"): node["path"].getStr() else: ""
    return
  let request = node["request"]
  result.verb = request["method"].getStr()
  result.path = request["path"].getStr()
  if request.hasKey("body"):
    result.body = request["body"].getStr()
  if request.hasKey("headers"):
    for key in request["headers"].keys:
      result.headers.add((key, request["headers"][key].getStr()))

proc expectedStatus(node: JsonNode): int =
  if node.hasKey("expect"): node["expect"]["status"].getInt()
  else: node["status"].getInt()

proc expectedBody(node: JsonNode): JsonNode =
  if node.hasKey("expect"): node["expect"]["body"]
  else: node["body"]

proc replayOne*(options: Options, name: string): bool =
  let target = casePath(options.dir, name)
  if not fileExists(target):
    stderr.writeLine "parity: case not found: " & target
    return false
  let document = parseFile(target)
  let stored = caseRequest(document)
  let verb = if options.verb.len > 0: options.verb.toUpperAscii() else: stored.verb
  let path = if options.path.len > 0: options.path else: stored.path
  let body =
    if options.body.len > 0 or options.bodyFile.len > 0: requestBody(options)
    else: stored.body
  let headers =
    if options.headers.len > 0: options.headers
    else: stored.headers
  let (status, responseBody) = send(options.base, verb, path, body, headers)

  var problems: seq[string] = @[]
  if status != expectedStatus(document):
    problems.add("status: expected " & $expectedStatus(document) & ", got " & $status)
  var actual: JsonNode
  try:
    actual = normalizeJson(parseJson(responseBody))
  except JsonParsingError:
    actual = %normalizePlainText(responseBody)
  if actual != expectedBody(document):
    problems.add("body differs")
    problems.add("  expected: " & $expectedBody(document).pretty)
    problems.add("  actual:   " & $actual.pretty)
  if problems.len > 0:
    for problem in problems:
      stderr.writeLine "parity: " & problem
    stderr.writeLine "  case: " & target
    return false
  echo "parity: ok " & name
  true

proc listCases(dir: string): seq[string] =
  if not dirExists(dir):
    fail(program, "cases directory not found: " & dir)
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".json") and
       path.extractFilename != "state.json":
      result.add(path.extractFilename[0 ..< path.extractFilename.len - 5])

proc namesFromSpec(spec: string): seq[string] =
  if not fileExists(spec):
    fail(program, "spec file not found: " & spec)
  for line in readFile(spec).splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0 or trimmed.startsWith("#"):
      continue
    result.add(line.split('\t')[0].strip())

proc replay*(options: Options) =
  var names = options.names
  if options.name.len > 0:
    names.insert(options.name, 0)
  if names.len == 0 and options.spec.len > 0:
    # A stateful corpus must replay in the order it was recorded.
    names = namesFromSpec(options.spec)
  if names.len == 0:
    names = listCases(options.dir)
    names.sort()
  if names.len == 0:
    fail(program, "no cases to replay in " & options.dir)
  var failures = 0
  for name in names:
    if not replayOne(options, name):
      failures.inc
  if failures > 0:
    stderr.writeLine "parity: " & $failures & " of " & $names.len & " cases failed"
    quit(1)
  echo "parity: " & $names.len & " cases ok"

# The lint and path helpers below are exported for tools/parity/tests (D-5,
# TL-08): they are pure, and until now only CI's corpus scan reached them.
proc routesFromSource*(path: string): seq[string] =
  ## The declared routes of the v1 corpus, one "METHOD /path" per line. The Go
  ## server that used to declare them is gone (T-082), so the list is frozen next
  ## to the corpus instead of being parsed out of source that no longer exists.
  if not fileExists(path):
    return @[]
  for line in readFile(path).splitLines():
    let route = line.strip()
    if route.len == 0 or route.startsWith("#"):
      continue
    result.add(route)

proc operationsFromSource*(path: string): seq[string] =
  ## `routes_gen.nim` is keyed by operation id, which is the stable name for a
  ## route whose path is a template.
  if not fileExists(path):
    return @[]
  const marker = "operationId: \""
  for line in readFile(path).splitLines():
    let at = line.find(marker)
    if at < 0:
      continue
    let start = at + marker.len
    let stop = line.find('"', start)
    if stop < 0:
      continue
    result.add(line[start ..< stop])

proc operationPathsFromSource(path: string): Table[string, string] =
  ## operationId -> path template, so a case's request path can be checked
  ## against the route it claims to exercise.
  if not fileExists(path):
    return
  const opMarker = "operationId: \""
  const pathMarker = "path: \""
  var operation = ""
  for line in readFile(path).splitLines():
    if line.contains(opMarker):
      let start = line.find(opMarker) + opMarker.len
      let stop = line.find('"', start)
      if stop > start:
        operation = line[start ..< stop]
    elif operation.len > 0 and line.contains(pathMarker):
      let start = line.find(pathMarker) + pathMarker.len
      let stop = line.find('"', start)
      if stop > start:
        result[operation] = line[start ..< stop]
        operation = ""

proc pathMatches*(expectedPath, actual: string): bool =
  ## Static segments must match literally; a `{...}` segment matches any
  ## non-empty one.
  let expected = expectedPath.strip(chars = {'/'}).split('/')
  let got = actual.strip(chars = {'/'}).split('/')
  if expected.len != got.len:
    return false
  for index in 0 ..< expected.len:
    let segment = expected[index]
    if segment.len >= 2 and segment[0] == '{' and segment[^1] == '}':
      if got[index].len == 0:
        return false
      continue
    if segment != got[index]:
      return false
  true

proc routePathTemplate*(route: string): string =
  ## The v1 corpus stores `METHOD /path` as the route; the v2 corpus stores an
  ## operation id, whose template comes from `routes_gen.nim`.
  let space = route.find(' ')
  if space > 0:
    for verbName in ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD",
                     "OPTIONS"]:
      if route[0 ..< space].toUpperAscii() == verbName:
        return route[space + 1 .. ^1].strip()
  ""

proc isNonEmptyBody(node: JsonNode): bool =
  case node.kind
  of JNull: false
  of JString: node.getStr().len > 0
  of JObject, JArray: node.len > 0
  of JBool, JInt, JFloat: true

proc lintErrorEnvelope*(name: string, status: int, body: JsonNode,
                        problems: var seq[string]) =
  ## A 4xx recorded from the Nim API must carry the problem+json envelope.
  ## Re-recording the corpus is how an intentional body change lands, so without
  ## this check the corpus would also accept a hand-built error body that skipped
  ## `problem()`. Every 4xx goes through `problem()`, including 429, so there is
  ## no exemption.
  if status < 400 or body.kind != JObject or body.len == 0:
    return
  if not body.hasKey("code") or body["code"].kind != JString:
    problems.add(name & ": 4xx body has no string code")
  if not body.hasKey("i18nKey") or body["i18nKey"].kind != JString:
    problems.add(name & ": 4xx body has no i18nKey")
  elif not body["i18nKey"].getStr().startsWith("error."):
    problems.add(name & ": i18nKey is not error.<name>")
  if not body.hasKey("status") or body["status"].kind != JInt:
    problems.add(name & ": 4xx body has no integer status")
  elif body["status"].getInt() != status:
    problems.add(name & ": 4xx body status does not match expect.status")

proc lintCase*(name: string, document: JsonNode,
               problems: var seq[string], rejected: var int): string =
  if not document.hasKey("expect"):
    problems.add(name & ": missing expect")
    return ""
  let expect = document["expect"]
  if not expect.hasKey("status") or expect["status"].kind != JInt:
    problems.add(name & ": expect.status missing or not an integer")
  elif expect["status"].getInt() >= 400:
    rejected.inc
  if not expect.hasKey("body"):
    problems.add(name & ": expect.body missing")
  elif not isNonEmptyBody(expect["body"]):
    if not (expect.hasKey("emptyBody") and expect["emptyBody"].getBool()):
      problems.add(name & ": expect.body is empty (set expect.emptyBody when 204)")
  elif expect.hasKey("emptyBody") and expect["emptyBody"].getBool():
    problems.add(name & ": expect.emptyBody is set but the body is not empty")
  elif expect.hasKey("status") and expect["status"].kind == JInt:
    lintErrorEnvelope(name, expect["status"].getInt(), expect["body"], problems)
  if document.hasKey("expectNim"):
    if not document.hasKey("expectedDivergence"):
      problems.add(name & ": expectNim without expectedDivergence")
    else:
      let divergence = document["expectedDivergence"]
      if not divergence.hasKey("reason") or
         divergence["reason"].getStr().strip().len == 0:
        problems.add(name & ": expectedDivergence.reason is empty")
      if not divergence.hasKey("owner") or
         divergence["owner"].getStr().strip().len == 0:
        problems.add(name & ": expectedDivergence.owner is empty")
  elif document.hasKey("expectedDivergence"):
    problems.add(name & ": expectedDivergence without expectNim")
  if not document.hasKey("request"):
    problems.add(name & ": missing request")
  else:
    let request = document["request"]
    if not request.hasKey("method") or request["method"].getStr().len == 0:
      problems.add(name & ": request.method missing")
    if not request.hasKey("path") or request["path"].getStr().len == 0:
      problems.add(name & ": request.path missing")
  if document.hasKey("route") and document["route"].getStr().len > 0:
    return document["route"].getStr()
  problems.add(name & ": route missing")
  ""

proc lint(options: Options) =
  let names = listCases(options.dir)
  if names.len == 0:
    fail(program, "no cases in " & options.dir)
  var problems: seq[string] = @[]
  var rejected = 0
  var routesOfCases: seq[string] = @[]
  let templates = operationPathsFromSource(options.routes)
  for name in names:
    let target = casePath(options.dir, name)
    var document: JsonNode
    try:
      document = parseFile(target)
    except JsonParsingError:
      problems.add(name & ": invalid JSON")
      continue
    let route = lintCase(name, document, problems, rejected)
    if route.len > 0:
      routesOfCases.add(route)
      if document.hasKey("request") and
         document["request"].kind == JObject and
         document["request"].hasKey("path"):
        let expectedPath =
          if templates.hasKey(route): templates[route]
          else: routePathTemplate(route)
        if expectedPath.len > 0 and
           not pathMatches(expectedPath, document["request"]["path"].getStr()):
          problems.add(name & ": request.path does not match " & expectedPath)

  let rejectedPct = rejected.float / names.len.float * 100.0
  if rejectedPct < 40.0:
    problems.add("only " & formatFloat(rejectedPct, ffDecimal, 1) &
      "% of cases assert status >= 400 (minimum is 40%)")

  var covered = 0
  let declared =
    if fileExists(options.routes) and
       readFile(options.routes).contains("operationId"):
      operationsFromSource(options.routes)
    else:
      routesFromSource(options.routes)
  if declared.len > 0:
    var missing: seq[string] = @[]
    for route in declared:
      if route notin routesOfCases:
        missing.add(route)
    if missing.len > 0:
      problems.add("routes without a case: " & missing.join(", "))
    for route in routesOfCases:
      if route notin declared:
        problems.add("case declares unknown route: " & route)
    covered = declared.len - missing.len
    echo "parity: routes " & $covered & "/" & $declared.len & " covered"

  echo "parity: cases=" & $names.len & " status>=400=" & $rejected &
    " (" & formatFloat(rejectedPct, ffDecimal, 1) & "%)"
  if problems.len > 0:
    for problem in problems:
      stderr.writeLine "parity: " & problem
    quit(1)
  echo "parity: corpus ok"

proc resetFixture(options: Options) =
  let fixture = options.dir / "fixture.sql"
  if not fileExists(fixture):
    fail(program, "fixture not found: " & fixture)
  let database = openParityDb(options)
  defer: database.close()
  database.tx(proc(conn: DbConn) =
    conn.execScript(readFile(fixture))
  )
  let keyring = loadKeyring(getEnv("SHARE_CODE_KEYS"),
    getEnv("SHARE_CODE_ACTIVE_KEY_ID"))
  let (keyId, encrypted) = encryptWith(keyring, fixtureShareCode,
    fixtureCommunity & "|" & fixtureLink)
  discard database.execUpdate(
    """insert into session.links
         (id, community_id, session_id, code_hash, code_enc, key_id, created_by)
       values ($1::uuid, $2::uuid, $3::uuid, sha256(convert_to($4,'utf8')),
               decode($5,'hex'), $6, $7::uuid)""",
    @[textParam(fixtureLink), textParam(fixtureCommunity),
      textParam(fixtureSession), textParam(fixtureShareCode),
      textParam(bytesHex(encrypted)), textParam(keyId),
      textParam(fixtureAdmin)])
  echo "parity: fixture reset (" & fixture & ")"

proc statePath(options: Options): string = options.dir / "state.json"

proc stateSnapshot(options: Options) =
  var state = parityState.loadState(options.statePath)
  let database = openParityDb(options)
  defer: database.close()
  parityState.snapshot(database, state)
  parityState.save(state)
  echo "parity: state snapshot written (" & $state.projections.len & " projections)"

proc stateCheck(options: Options) =
  let state = parityState.loadState(options.statePath)
  let database = openParityDb(options)
  defer: database.close()
  let problems = parityState.digestProblems(database, state)
  if problems.len > 0:
    for problem in problems:
      stderr.writeLine "parity: " & problem
    quit(1)
  echo "parity: state ok (" & $state.projections.len & " projections)"

proc stateSelftest(options: Options) =
  let state = parityState.loadState(options.statePath)
  let database = openParityDb(options)
  defer: database.close()
  let problems = parityState.selftest(database, state)
  if problems.len > 0:
    for problem in problems:
      stderr.writeLine "parity: " & problem
    quit(1)
  echo "parity: state selftest ok (mutation changes the hash and is rolled back)"

proc main*() =
  ## Exported for tools/parity/tests (D-5, TL-08) so the lint floor can be
  ## driven as a subprocess over a temporary corpus.
  let options = parseArgs()
  case options.command
  of "record":
    if options.spec.len > 0:
      recordSpec(options)
    else:
      recordOne(options)
  of "replay": replay(options)
  of "lint": lint(options)
  of "reset": resetFixture(options)
  of "state-snapshot": stateSnapshot(options)
  of "state-check": stateCheck(options)
  of "state-selftest": stateSelftest(options)
  else: usageFail(program, "unknown command: " & options.command)

when isMainModule:
  main()
