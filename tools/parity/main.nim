import std/[algorithm, httpclient, json, os, strutils]
import normalizer

const
  defaultDir = "testdata/parity/v1"
  defaultBase = "http://127.0.0.1:8091"

proc fail(message: string) {.noreturn.} =
  stderr.writeLine "parity: " & message
  quit(1)

type
  Options = object
    command, base, dir, name, verb, path, body, bodyFile, route, spec, routes: string
    headers: seq[(string, string)]
    names: seq[string]

proc parseHeader(value: string): (string, string) =
  let colon = value.find(':')
  if colon <= 0:
    fail "invalid header (expected \"Name: value\"): " & value
  (value[0 ..< colon].strip(), value[colon + 1 .. ^1].strip())

proc parseArgs(): Options =
  result.verb = ""
  result.dir = defaultDir
  result.base = defaultBase
  if paramCount() < 1:
    fail "usage: parity record|lint|replay [options]"
  result.command = paramStr(1)
  var index = 2
  while index <= paramCount():
    case paramStr(index)
    of "--base":
      index.inc; result.base = paramStr(index)
    of "--dir":
      index.inc; result.dir = paramStr(index)
    of "--name":
      index.inc; result.name = paramStr(index)
    of "--method":
      index.inc; result.verb = paramStr(index)
    of "--path":
      index.inc; result.path = paramStr(index)
    of "--body":
      index.inc; result.body = paramStr(index)
    of "--body-file":
      index.inc; result.bodyFile = paramStr(index)
    of "--route":
      index.inc; result.route = paramStr(index)
    of "--spec":
      index.inc; result.spec = paramStr(index)
    of "--routes":
      index.inc; result.routes = paramStr(index)
    of "--header":
      index.inc; result.headers.add(parseHeader(paramStr(index)))
    else:
      if paramStr(index).startsWith("--"):
        fail "unknown argument: " & paramStr(index)
      result.names.add(paramStr(index))
    index.inc

proc casePath(dir, name: string): string = dir / (name & ".json")

proc requestBody(options: Options): string =
  if options.bodyFile.len > 0:
    if not fileExists(options.bodyFile):
      fail "body file not found: " & options.bodyFile
    result = readFile(options.bodyFile)
  else:
    result = options.body

proc send(base, verbText, path, body: string, headers: seq[(string, string)]): (int, string) =
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
  else: fail "unsupported method: " & verbText
  let response = client.request(base & path, httpMethod = verb, body = body)
  (response.code.int, response.body)

proc responseExpectation(status: int, body: string): JsonNode =
  result = newJObject()
  result["status"] = %status
  try:
    result["body"] = normalizeJson(parseJson(body))
  except JsonParsingError:
    result["body"] = %normalizePlainText(body)

proc recordOne(options: Options) =
  if options.name.len == 0:
    fail "--name is required for record"
  if options.path.len == 0:
    fail "--path is required for record"
  let verb = if options.verb.len > 0: options.verb.toUpperAscii() else: "GET"
  let body = requestBody(options)
  let (status, responseBody) = send(options.base, verb, options.path, body, options.headers)

  var route = options.route
  let target = casePath(options.dir, options.name)
  if route.len == 0 and fileExists(target):
    # Keep the route template of an existing case when it is not repeated.
    try:
      route = parseFile(target)["route"].getStr()
    except JsonParsingError, KeyError:
      discard

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

  createDir(options.dir)
  writeFile(target, pretty(document, indent = 2) & "\n")
  echo "parity: recorded " & target & " (" & $status & ")"

proc recordSpec(options: Options) =
  if not fileExists(options.spec):
    fail "spec file not found: " & options.spec
  var count = 0
  for line in readFile(options.spec).splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0 or trimmed.startsWith("#"):
      continue
    let fields = line.split('\t')
    if fields.len != 6:
      fail "invalid spec line (expected 6 tab-separated fields): " & line
    var single = options
    single.spec = ""
    single.name = fields[0].strip()
    single.route = fields[1].strip()
    single.verb = fields[2].strip()
    single.path = fields[3].strip()
    single.headers = @[]
    if fields[4].strip() != "-":
      single.headers.add(parseHeader(fields[4].strip()))
    single.bodyFile = ""
    single.body = if fields[5].strip() == "-": "" else: fields[5]
    recordOne(single)
    count.inc
  echo "parity: recorded " & $count & " cases from " & options.spec

proc caseRequest(node: JsonNode): tuple[verb, path, body: string, headers: seq[(string, string)]] =
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

proc replayOne(options: Options, name: string): bool =
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
    fail "cases directory not found: " & dir
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".json"):
      result.add(path.extractFilename[0 ..< path.extractFilename.len - 5])

proc replay(options: Options) =
  var names = options.names
  if options.name.len > 0:
    names.insert(options.name, 0)
  if names.len == 0:
    names = listCases(options.dir)
  if names.len == 0:
    fail "no cases to replay in " & options.dir
  names.sort()
  var failures = 0
  for name in names:
    if not replayOne(options, name):
      failures.inc
  if failures > 0:
    stderr.writeLine "parity: " & $failures & " of " & $names.len & " cases failed"
    quit(1)
  echo "parity: " & $names.len & " cases ok"

proc routesFromSource(path: string): seq[string] =
  if not fileExists(path):
    return @[]
  const marker = "mux.Handle(\""
  for line in readFile(path).splitLines():
    let at = line.find(marker)
    if at < 0:
      continue
    let start = at + marker.len
    let stop = line.find('"', start)
    if stop < 0:
      continue
    result.add(line[start ..< stop])

proc isNonEmptyBody(node: JsonNode): bool =
  case node.kind
  of JNull: false
  of JString: node.getStr().len > 0
  of JObject, JArray: node.len > 0
  of JBool, JInt, JFloat: true

proc lint(options: Options) =
  let names = listCases(options.dir)
  if names.len == 0:
    fail "no cases in " & options.dir
  var problems: seq[string] = @[]
  var rejected = 0
  var routesOfCases: seq[string] = @[]
  for name in names:
    let target = casePath(options.dir, name)
    var document: JsonNode
    try:
      document = parseFile(target)
    except JsonParsingError:
      problems.add(name & ": invalid JSON")
      continue
    if not document.hasKey("expect"):
      problems.add(name & ": missing expect")
      continue
    let expect = document["expect"]
    if not expect.hasKey("status") or expect["status"].kind != JInt:
      problems.add(name & ": expect.status missing or not an integer")
    elif expect["status"].getInt() >= 400:
      rejected.inc
    if not expect.hasKey("body"):
      problems.add(name & ": expect.body missing")
    elif not isNonEmptyBody(expect["body"]):
      problems.add(name & ": expect.body is empty")
    if not document.hasKey("request"):
      problems.add(name & ": missing request")
    else:
      let request = document["request"]
      if not request.hasKey("method") or request["method"].getStr().len == 0:
        problems.add(name & ": request.method missing")
      if not request.hasKey("path") or request["path"].getStr().len == 0:
        problems.add(name & ": request.path missing")
    if document.hasKey("route") and document["route"].getStr().len > 0:
      routesOfCases.add(document["route"].getStr())
    else:
      problems.add(name & ": route missing")

  let rejectedPct = rejected.float / names.len.float * 100.0
  if rejectedPct < 40.0:
    problems.add("only " & formatFloat(rejectedPct, ffDecimal, 1) &
      "% of cases assert status >= 400 (minimum is 40%)")

  var covered = 0
  let declared = routesFromSource(options.routes)
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

proc main() =
  let options = parseArgs()
  case options.command
  of "record":
    if options.spec.len > 0:
      recordSpec(options)
    else:
      recordOne(options)
  of "replay": replay(options)
  of "lint": lint(options)
  else: fail "unknown command: " & options.command

when isMainModule:
  main()
