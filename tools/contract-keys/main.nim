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
## This checker walks `routes_gen`, so a spec edit that forgets either key fails
## here with the operation named instead of in review.

import std/[json, os, sets]

import cli

import api/src/routes_gen
import api/src/route_access
import account/domain/roles

const
  program = "contract-keys"
  matrixPath = "testdata/authz/matrix.yaml"
  accessTablePath = "apps/api/src/route_access.nim"

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

proc main*() =
  for argument in commandLineParams():
    case argument
    of "--help", "-h":
      echo "Usage: contract-keys"
      echo "Fails when a contract operation has no access-table key, no explicit"
      echo "rule in " & accessTablePath & ", or a class the matrix disagrees with."
      quit(0)
    else:
      usageFail(program, "unknown argument: " & argument)

  let found = problems(routes, loadMatrix(), operationAccess, operationKnown)
  if found.len > 0:
    stderr.writeLine "contract-keys: " & $found.len & " problem(s)"
    for line in found:
      stderr.writeLine "  " & line
    stderr.writeLine "add the matrix row, then the rule in " & accessTablePath &
      " (see testdata/authz/matrix.yaml)"
    quit(1)
  echo "contract-keys: ok (" & $routes.len & " operations)"

when isMainModule:
  main()
