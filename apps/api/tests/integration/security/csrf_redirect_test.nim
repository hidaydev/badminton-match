import std/[httpclient, json, options, unittest]
import db/db
import mummy
import sha256
import tests/fixtures
import ../../http_support

const
  port = testPort(18099)
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  foreignOrigin = "https://evil.example"

var
  database: Db
  userId: string

proc bootstrap() =
  database = openDb(dsn(), 1)
  cleanupUsers(database, "csrf-%")
  discard database.execUpdate("delete from auth.oauth_flows")
  userId = newUser(database, "csrf-user", "csrf-user@example.com")
  startServer(newTestApp(database), port, baseUrl)

proc storedReturnTo(state: string): string =
  let row = database.queryOne(
    """select return_to from auth.oauth_flows
       where state_hash = decode($1, 'hex')""",
    @[textParam(sha256Hex(state))])
  if row.isSome: row.get.get("return_to") else: ""

proc startFlow(returnTo: string): (int, string) =
  let response = call(baseUrl, HttpPost, "/auth/start",
    body = $ %*{"returnTo": returnTo})
  var state = ""
  if response.status == 200:
    state = queryParam(response.json["authorizeUrl"].getStr(), "state")
  (response.status, state)

requireDatabase()

bootstrap()

suite "security: CSRF / origin":
  test "v1-red/v2-green: a state-changing request with a foreign Origin is rejected":
    let session = cookieFor(database, userId)
    let rejected = call(baseUrl, HttpPost, "/auth/logout", session,
      origin = foreignOrigin)
    expectProblem(rejected, 403, "CSRF_REJECTED")
    # The rejected request must not have acted: the session still resolves.
    let still = call(baseUrl, HttpGet, "/auth/me", session)
    expectStatus(still, 200)

  test "v1-red/v2-green: a cookie request without Origin is rejected":
    let session = cookieFor(database, userId)
    let rejected = call(baseUrl, HttpPost, "/auth/logout", session, origin = "")
    expectProblem(rejected, 403, "CSRF_REJECTED")
    let still = call(baseUrl, HttpGet, "/auth/me", session)
    expectStatus(still, 200)

  test "Sec-Fetch-Site is enforced when Origin is absent":
    expectProblem(call(baseUrl, HttpPost, "/auth/logout", origin = "",
      extra = [("Sec-Fetch-Site", "cross-site")]), 403, "CSRF_REJECTED")
    expectProblem(call(baseUrl, HttpPost, "/auth/logout", origin = "",
      extra = [("Sec-Fetch-Site", "same-site")]), 403, "CSRF_REJECTED")
    expectStatus(call(baseUrl, HttpPost, "/auth/logout", origin = "",
      extra = [("Sec-Fetch-Site", "same-origin")]), 204)
    expectStatus(call(baseUrl, HttpPost, "/auth/logout", origin = "",
      extra = [("Sec-Fetch-Site", "none")]), 204)

  test "the allowed Origin passes and safe methods are never blocked":
    let session = cookieFor(database, userId)
    expectStatus(call(baseUrl, HttpPost, "/auth/logout", session,
      origin = allowedOrigin), 204)
    let fresh = cookieFor(database, userId)
    expectStatus(call(baseUrl, HttpGet, "/healthz", origin = foreignOrigin), 200)
    expectStatus(call(baseUrl, HttpGet, "/auth/me", fresh,
      origin = foreignOrigin), 200)

  test "the leniency covers only requests without the session cookie":
    # No cookie and no Origin is not a browser request: CLI and health checks
    # keep working, exactly as `csrfCheck` documents.
    expectStatus(call(baseUrl, HttpPost, "/auth/logout", origin = ""), 204)

suite "security: open redirect":
  test "v1-red/v2-green: return_to keeps only a same-origin path":
    for target in ["//evil", "/\\evil", "%2F%2Evil", "https://evil",
                   "/%2F%2Fevil", "/a//b", "/../etc"]:
      let (status, state) = startFlow(target)
      check status == 200
      check state.len > 0
      checkpoint("return_to for " & target)
      check storedReturnTo(state) == "/"

  test "a same-origin path is preserved for the callback":
    let (status, state) = startFlow("/sessions/42")
    check status == 200
    check state.len > 0
    check storedReturnTo(state) == "/sessions/42"

  test "a malformed start body is a 400, not a 500":
    let response = call(baseUrl, HttpPost, "/auth/start", body = "{")
    response.expectProblem(400, "INVALID_BODY")

  test "a valid JSON body that is not an object is a 400, not a 500":
    # Every route reads the body as an object; a bare array used to reach
    # `hasKey` and raise a defect, which surfaced as a 500.
    for body in ["[]", "\"x\"", "1", "null"]:
      expectProblem(call(baseUrl, HttpPost, "/auth/start", body = body),
        400, "INVALID_BODY")

  test "a body nested past the configured depth is a 400":
    var deep = ""
    for _ in 0 ..< 17: deep.add('[')
    for _ in 0 ..< 17: deep.add(']')
    expectProblem(call(baseUrl, HttpPost, "/auth/start", body = deep),
      400, "INVALID_BODY")
    # At the configured limit the door stays open.
    var allowed = ""
    for _ in 0 ..< 16: allowed.add("""{"a":""")
    allowed.add("1")
    for _ in 0 ..< 16: allowed.add("}")
    expectStatus(call(baseUrl, HttpPost, "/auth/start", body = allowed), 200)

  test "v1-red/v2-green: the legacy GET start route cannot start a flow":
    # v1 exposed GET /auth/google/start?return_to=...; v2's contract is
    # POST /auth/start with a JSON body, so neither shape can be abused.
    expectProblem(call(baseUrl, HttpGet,
      "/auth/google/start?return_to=//evil"), 404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpGet,
      "/auth/start?return_to=//evil"), 405, "METHOD")

suite "security: response caching":
  test "the identity response is never stored by a shared cache":
    let session = cookieFor(database, userId)
    let me = call(baseUrl, HttpGet, "/auth/me", session)
    expectStatus(me, 200)
    check header(me, "Cache-Control") == "no-store"
