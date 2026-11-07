import std/[strutils, unittest]
import db/db
import ../src/routes_gen
import ./http_support

# One server for the whole suite, the same anonymous request path a probe or a
# CLI uses. No session fixture: a `/c/{slug}/...` path stops at the auth gate
# before a handler is chosen, so the answer alone proves the branch was reached.
const
  port = testPort(18103)
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  # `routeNotFound` is the only producer of this sentence in app.nim, so a body
  # that contains it can only come from the final fallthrough.
  fallthroughDetail = "route not found"
  # Id-shaped parameters are cast to uuid on the way to a handler. A well-formed
  # placeholder keeps a reached branch from turning into a cast error.
  sampleId = "00000000-0000-4000-8000-000000000000"

requireDatabase()

let database = openDb(dsn(), 1)
startServer(newTestApp(database), port, baseUrl)

proc concretize(path: string): string =
  ## Fills every `{name}` with a value the dispatch branch can pass on. Only an
  ## unknown slug or share code is needed: both answer before a row is read, so
  ## the value has to be well formed, never real.
  var name = ""
  var inParam = false
  for character in path:
    case character
    of '{':
      inParam = true
      name.setLen(0)
    of '}':
      inParam = false
      case name
      of "slug": result.add("dispatch-slug")
      of "code": result.add("dispatch-code")
      of "token": result.add("dispatch-token")
      of "gameKey": result.add("1")
      else: result.add(sampleId)
    else:
      if inParam: name.add(character) else: result.add(character)

proc verbOf(spec: RouteSpec): HttpMethod =
  ## The contract verb. Sending anything else would be answered by the 405 arm
  ## of a branch and prove nothing about this operation.
  case spec.httpMethod
  of "GET": HttpGet
  of "POST": HttpPost
  of "PATCH": HttpPatch
  of "PUT": HttpPut
  of "DELETE": HttpDelete
  else:
    raise newException(ValueError, "unmapped method: " & spec.httpMethod)

suite "generated route dispatch":
  test "every contract operation reaches a dispatch branch":
    # The request carries no cookie, Origin, X-API-Version or body, so the four
    # guards in front of the dispatch (CSRF, body size, quota per route, client
    # version) cannot answer. Whatever comes back therefore comes from a
    # dispatch branch: a handler, the auth gate a handler sits behind, or the
    # method/not-found arm inside the branch. Only the fallthrough is missing.
    for spec in routes:
      let path = concretize(spec.path)
      let response = call(baseUrl, verbOf(spec), path, origin = "",
        maxRedirects = 0)
      checkpoint(spec.operationId & ": " & spec.httpMethod & " " & spec.path &
        " -> " & $response.status & " " & response.body)
      check response.body.find(fallthroughDetail) < 0