import std/[json, options, strutils, unittest]
import db/db
import ../../src/routes_gen
import ../http_support

# The anonymous request sweep. One server for the whole suite, the same path a
# probe or a CLI uses, and one expectation per operation read from the access
# matrix: a session row must answer 401 or 403, and a public row must answer a
# normal 2xx/4xx instead of a server fault. The expected class comes from
# `testdata/authz/matrix.yaml`, never from `route_access`, so patching the
# classifier to call a write route public fails this test instead of agreeing
# with it.
let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  # `routeNotFound` is the only producer of this sentence in app.nim, so a body
  # that contains it can only come from the final fallthrough.
  fallthroughDetail = "route not found"
  matrixPath = "testdata/authz/matrix.yaml"
  # Id-shaped parameters are cast to uuid on the way to a handler. A well-formed
  # placeholder keeps a reached branch from turning into a cast error.
  sampleId = "00000000-0000-4000-8000-000000000000"

requireDatabase()

let database = openDb(dsn(), 1)
startServer(newTestApp(database), port, baseUrl)

proc loadMatrix(): JsonNode =
  let document = parseFile(matrixPath)
  if not document.hasKey("operations"):
    raise newException(ValueError, matrixPath & ": missing operations")
  document["operations"]

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

proc sessionAnswer(operationId: string, status: int): bool =
  ## A session row must be refused with the unauthenticated or forbidden code.
  ## Two documented exceptions:
  ##   wsSession      the channel is resolved before the handshake ticket is
  ##                  read, so an unknown session id is a 404. Still a refusal.
  ##   postAuthLogout logout is an idempotent no-op: it clears a cookie that may
  ##                  not exist and grants nothing, so it answers 204. The
  ##                  sweep below proves it does not create a session row.
  if operationId == "wsSession":
    return status in [401, 403, 404]
  if operationId == "postAuthLogout":
    return status == 204
  status in [401, 403]

proc sessionCount(): string =
  database.queryOne(
    "select count(*)::int as n from account.sessions").get.get("n")

proc communityCount(): string =
  database.queryOne(
    "select count(*)::int as n from platform.community").get.get("n")

suite "generated route dispatch":
  test "every contract operation is refused or answered as the matrix declares":
    # The request carries no cookie, Origin, X-API-Version or body, so the four
    # guards in front of the dispatch (CSRF, body size, quota per route, client
    # version) cannot answer. Whatever comes back therefore comes from a
    # dispatch branch: a handler, the auth gate a handler sits behind, or the
    # method/not-found arm inside the branch. Only the fallthrough is missing.
    let operations = loadMatrix()
    for spec in routes:
      if not operations.hasKey(spec.operationId):
        checkpoint spec.operationId & ": no row in " & matrixPath
      let row = operations[spec.operationId]
      let isPublic = row["auth"].getStr() == "public"
      let path = concretize(spec.path)
      let response = call(baseUrl, verbOf(spec), path, origin = "",
        maxRedirects = 0)
      let expected = if isPublic: "public (2xx/4xx)" else: "session (401/403)"
      checkpoint(spec.operationId & ": " & spec.httpMethod & " " & spec.path &
        " -> " & $response.status & " " & response.body &
        " (matrix: " & expected & ")")
      check response.body.find(fallthroughDetail) < 0
      if isPublic:
        # The three public doors and the share URLs may answer 4xx because the
        # placeholder code names no row; a 5xx is a fault the matrix does not
        # declare.
        check response.status in 200 .. 499
      else:
        check sessionAnswer(spec.operationId, response.status)

  test "an anonymous logout does not create a session":
    let before = sessionCount()
    let response = call(baseUrl, HttpPost, "/auth/logout", origin = "")
    checkpoint("logout anonymous -> " & $response.status & " " & response.body)
    check response.status == 204
    check sessionCount() == before

  test "a refused write does not create a row":
    # The same anonymous path a session route takes must not reach the handler.
    # `createCommunity` is the widest write in the API, so a bypass would be
    # visible as a new row even though the response stayed a 401.
    let before = communityCount()
    let response = call(baseUrl, HttpPost, "/communities", origin = "", body = """
      {"slug":"dispatch-refused","name":"Refused","adminEmail":"refused@example.com","timezone":"Asia/Jakarta"}
      """)
    checkpoint("createCommunity anonymous -> " & $response.status & " " &
      response.body)
    check response.status == 401
    check communityCount() == before

  test "a member is refused every host and admin route":
    # The anonymous sweep proves the session gate; this one proves the role
    # gate behind it. A member who is refused must see 403, and a route with no
    # role list must not answer 403. Patching `operationAccess` to call a write
    # route public makes the handler run, so the expected 403 stops being the
    # answer and this test fails.
    discard database.execUpdate(
      """delete from community.membership
         where user_id in (select id from platform.user
                           where google_sub = 'dispatch-member')""")
    discard database.execUpdate(
      "delete from platform.user where google_sub = 'dispatch-member'")
    discard database.execUpdate(
      "delete from platform.community where slug = 'dispatch-member'")
    let communityId = database.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ('dispatch-member', 'Dispatch Member', 'Asia/Jakarta')
         returning id::text as id""").get.get("id")
    let userId = database.queryOne(
      """insert into platform.user (google_sub, email_hash, display_name)
         values ('dispatch-member', 'dispatch-member-hash', 'Dispatch Member')
         returning id::text as id""").get.get("id")
    discard database.execUpdate(
      """insert into community.membership (community_id, user_id, role)
         values ($1::uuid, $2::uuid, 'member')""",
      @[textParam(communityId), textParam(userId)])
    let cookie = cookieFor(database, userId)

    let operations = loadMatrix()
    let playersBefore = database.queryOne(
      """select count(*)::int as n from player.players
         where community_id = $1::uuid""", @[textParam(communityId)]).get.get("n")
    for spec in routes:
      if not spec.path.startsWith("/c/{"):
        continue
      let row = operations[spec.operationId]
      let needsRole = row.hasKey("roles")
      let path = concretize(spec.path).replace("/c/dispatch-slug",
        "/c/dispatch-member")
      let response = call(baseUrl, verbOf(spec), path, cookie = cookie,
        origin = allowedOrigin, maxRedirects = 0)
      let expected =
        if needsRole: "403 (member is below " & $row["roles"] & ")"
        else: "not 403/401"
      checkpoint(spec.operationId & ": member " & spec.httpMethod & " " &
        spec.path & " -> " & $response.status & " " & response.body &
        " (matrix: " & expected & ")")
      check response.body.find(fallthroughDetail) < 0
      if needsRole:
        check response.status == 403
        check response.body.find("\"code\":\"FORBIDDEN\"") >= 0
      else:
        check response.status notin [401, 403]
    let playersAfter = database.queryOne(
      """select count(*)::int as n from player.players
         where community_id = $1::uuid""", @[textParam(communityId)]).get.get("n")
    check playersAfter == playersBefore
    discard database.execUpdate(
      """delete from community.membership
         where community_id = $1::uuid""", @[textParam(communityId)])
    discard database.execUpdate(
      "delete from platform.user where id = $1::uuid", @[textParam(userId)])
    discard database.execUpdate(
      "delete from platform.community where id = $1::uuid",
      @[textParam(communityId)])
