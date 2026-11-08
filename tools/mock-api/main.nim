import std/[os, strutils]
import mummy
import api/src/routes_gen

proc matches*(routePath, actual: string): bool =
  ## Exported for `tests/mockapi_test.nim` only (D-5): the matcher is the one
  ## piece of logic the mock owns, and a change to the `{param}` or literal rule
  ## silently changes which requests the mock answers.
  let expected = routePath.split('/')
  let got = actual.split('/')
  if expected.len != got.len:
    return false
  for index in 0 ..< expected.len:
    if expected[index].len > 1 and expected[index][0] == '{':
      if got[index].len == 0:
        return false
    elif expected[index] != got[index]:
      return false
  true

proc handle(request: Request) {.gcsafe.} =
  for route in routes:
    if route.httpMethod == request.httpMethod and matches(route.path, request.path):
      let body = """{"mock":""" & "\"" & route.operationId & "\"" & "}"
      request.respond(200, @[("Content-Type", "application/json")], body)
      return
  request.respond(404, @[("Content-Type", "application/json")], """{"error":"not_found"}""")

proc main() =
  let port = parseInt(getEnv("MOCK_API_PORT", "8090"))
  echo "mock-api: " & $routeCount & " operations on port " & $port
  let server = newServer(handle, workerThreads = 2)
  server.serve(Port(port), "127.0.0.1")

when isMainModule:
  main()
