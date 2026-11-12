## SEC-10: the access table side of the contract, checked as a gate.
##
## `./task contract-check` proves the specs and the generated files agree. It
## said nothing about the two key sets the request path actually reads:
##
##   1 `testdata/authz/matrix.yaml` must hold one row per contract operation.
##   2 `apps/api/src/route_access.nim` must classify that operation's shape with
##     an explicit rule. The table used to end in `readAccess()`, so a contract
##     route it never learned looked exactly like a deliberate member route:
##     the matrix row "session" agreed with the fallback and every test passed.
##
##   3 The request keys must agree in both directions. `tools/contract-gen`
##     emits the keys each operation declares (request-body properties plus
##     path and query parameters); this checker collects the keys the request
##     path actually reads (`optStr(body, "x")`, `body["x"]`, and
##     `request.queryParams["x"]`) and names a read key no operation declares
##     and a declared key nothing reads.
##
## It deliberately never claims which handler serves which operation. Binding a
## dispatch proc to an operation id means duplicating the dispatch tree, and a
## stale binding reports green over a wrong table (ADR-020). The three idioms
## are the whole vocabulary; a key read some other way is neither declared nor
## checked, and that limit is the point of this paragraph.

import std/[algorithm, json, os, sets, strutils, tables]

import cli

import api/src/routes_gen
import api/src/route_access
import account/domain/roles

const
  program = "contract-keys"
  matrixPath = "testdata/authz/matrix.yaml"
  accessTablePath = "apps/api/src/route_access.nim"
  appPath = "apps/api/src/app.nim"

proc concrete(path: string): string =
  ## One value per path parameter: the classifier reads the shape, never the
  ## value, so any concrete segment answers the same question.
  result = path
  var inside = false
  for index in 0 ..< result.len:
    if result[index] == '{':
      inside = true
      result[index] = 'x'
    elif result[index] == '}':
      inside = false
      result[index] = 'x'
    elif inside:
      result[index] = 'x'

proc loadMatrix*(): JsonNode =
  ## Exported for the suite, which feeds the checker the committed matrix.
  if not fileExists(matrixPath):
    fail(program, "missing " & matrixPath)
  var document: JsonNode
  try:
    document = parseFile(matrixPath)
  except CatchableError as error:
    fail(program, matrixPath & ": " & error.msg)
  if not document.hasKey("operations") or document["operations"].kind != JObject:
    fail(program, matrixPath & ": missing operations")
  document["operations"]

proc problems*(routes: openArray[RouteSpec], operations: JsonNode,
               accessOf: proc(verb, path: string): Access,
               known: proc(verb, path: string): bool): seq[string] =
  ## One line per missing binding, naming the operation and its shape.
  var declared = initHashSet[string]()
  for route in routes:
    let operationId = route.operationId
    declared.incl operationId
    let label = route.httpMethod & " " & route.path
    if not operations.hasKey(operationId):
      result.add operationId & " (" & label & "): no row in " & matrixPath
      continue
    var expected: Access
    try:
      expected = parseAccess(operations[operationId])
    except CatchableError as error:
      result.add operationId & " (" & label & "): " & matrixPath & " row is " &
        "unreadable: " & error.msg
      continue
    let shape = concrete(route.path)
    if not known(route.httpMethod, shape):
      result.add operationId & " (" & label & "): no explicit rule in " &
        accessTablePath
    let dispatched = accessOf(route.httpMethod, shape)
    if dispatched.describe() != expected.describe():
      result.add operationId & " (" & label & "): the dispatch grants " &
        dispatched.describe() & ", " & matrixPath & " declares " &
        expected.describe()
  for operationId in operations.keys:
    if operationId notin declared:
      result.add operationId & ": " & matrixPath & " has a row for an " &
        "operation the contract does not declare"

proc declaredKeys*(routes: openArray[RouteSpec]): Table[string, string] =
  ## Key -> the first operation that declares it, so a stale declaration names
  ## where to look. Empty fields (",,") are skipped. Path parameters are not
  ## part of this set: they are read from the split path, not from the body or
  ## the query string, so they can never be "read but undeclared" here.
  for route in routes:
    for field in [route.requestKeys, route.queryParams]:
      for name in field.split(','):
        if name.len == 0 or result.hasKey(name):
          continue
        result[name] = route.operationId

proc readKeys*(source: string): seq[string] =
  ## The three idioms ADR-020 names, and nothing else. An assignment
  ## (`body["x"] = ...`) is writing a response field, not reading a request
  ## key, so it is skipped; whitespace before `=` does not hide one.
  const
    optPrefix = "optStr(body, \""
    bodyPrefix = "body[\""
    queryPrefix = "request.queryParams[\""
  var found = initHashSet[string]()
  for line in source.splitLines():
    var index = 0
    while index < line.len:
      let call = line.find(optPrefix, index)
      let bracket = line.find(bodyPrefix, index)
      let query = line.find(queryPrefix, index)
      var chosen = -1
      var kind = 0
      if call >= 0:
        chosen = call
        kind = 1
      if query >= 0 and (chosen < 0 or query < chosen):
        chosen = query
        kind = 3
      if bracket >= 0 and (chosen < 0 or bracket < chosen):
        chosen = bracket
        kind = 2
      if chosen < 0:
        break
      let start =
        case kind
        of 1: chosen + optPrefix.len
        of 2: chosen + bodyPrefix.len
        else: chosen + queryPrefix.len
      let close = line.find('"', start)
      if close < 0:
        break
      if kind == 2:
        var rest = line[close + 1 .. ^1].strip()
        if rest.startsWith("]"):
          rest = rest[1 .. ^1].strip()
        if rest.len == 0 or rest.startsWith("="):
          index = close + 1
          continue
      found.incl line[start ..< close]
      index = close + 1
  for name in found:
    result.add name
  result.sort()

proc keyProblems*(routes: openArray[RouteSpec], source: string): seq[string] =
  ## Both directions: a read key nobody declared, a declared key nobody reads.
  let declared = declaredKeys(routes)
  var read = initHashSet[string]()
  for name in readKeys(source):
    read.incl name
    if not declared.hasKey(name):
      result.add name & ": read in " & appPath &
        " but no contract operation declares it"
  for name in declared.keys:
    if name notin read:
      result.add name & ": declared by " & declared[name] &
        " but nothing in " & appPath & " reads it"
  result.sort()

proc main*() =
  for argument in commandLineParams():
    case argument
    of "--help", "-h":
      echo "Usage: contract-keys"
      echo "Fails when a contract operation has no access-table key, no explicit"
      echo "rule in " & accessTablePath & ", a class the matrix disagrees with,"
      echo "a request key the handler reads but the contract never declares, or"
      echo "a request key the contract declares and no handler reads."
      quit(0)
    else:
      usageFail(program, "unknown argument: " & argument)

  let matrix = loadMatrix()
  var found = problems(routes, matrix, operationAccess, operationKnown)
  if not fileExists(appPath):
    fail(program, "missing " & appPath)
  found.add keyProblems(routes, readFile(appPath))
  if found.len > 0:
    stderr.writeLine "contract-keys: " & $found.len & " problem(s)"
    for line in found:
      stderr.writeLine "  " & line
    stderr.writeLine "add the matrix row, then the rule in " & accessTablePath &
      ", and declare the key in packages/contracts/openapi (see " &
      "testdata/authz/matrix.yaml)"
    quit(1)
  echo "contract-keys: ok (" & $routes.len & " operations, " &
    $declaredKeys(routes).len & " request keys)"

when isMainModule:
  main()
