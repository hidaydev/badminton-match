import std/[exitprocs, httpclient, json, options, os, osproc, strutils, unittest, uri]
import db/db
import mummy
import sha256
import ../../src/app
import account/infrastructure/oidc
import platform/config/store
import share/crypto
import ../http_support

const
  baseUrl = "http://127.0.0.1:18103"
  port = Port(18103)
  stubBase = "http://127.0.0.1:18177"
  clientId = "t070-client"
  redirectUri = "http://127.0.0.1:5173/api/auth/callback"

var
  database: Db
  stubProcess: Process

proc repoRoot(): string =
  var dir = getCurrentDir()
  for _ in 0 ..< 6:
    if fileExists(dir / "tools/oidc-stub/main.nim"):
      return dir
    dir = parentDir(dir)
  getCurrentDir()

proc ensureStub(): string =
  result = getEnv("OIDC_STUB_BIN", "")
  if result.len > 0 and fileExists(result):
    return
  result = getTempDir() / "oidc-stub-t070"
  if fileExists(result):
    return
  let repo = repoRoot()
  let (output, code) = execCmdEx("nim c --hints:off -o:" &
    quoteShell(result) & " " & quoteShell(repo / "tools/oidc-stub/main.nim"))
  doAssert code == 0, "cannot build the OIDC stub: " & output

proc stopStub() {.noconv.} =
  if stubProcess != nil:
    try:
      terminate(stubProcess)
    except CatchableError:
      discard

proc startStub() =
  let bin = ensureStub()
  putEnv("OIDC_STUB_PORT", "18177")
  putEnv("OIDC_STUB_ISSUER", stubBase)
  putEnv("OIDC_STUB_CLIENT_ID", clientId)
  stubProcess = startProcess(bin, workingDir = repoRoot(), args = [])
  addExitProc(stopStub)
  var up = false
  for _ in 0 ..< 200:
    try:
      let client = newHttpClient(timeout = 1000)
      defer: client.close()
      if client.get(stubBase & "/healthz").code.int == 200:
        up = true
        break
    except CatchableError:
      discard
    sleep(50)
  doAssert up, "oidc stub did not start on " & stubBase

proc bootstrap() =
  database = openDb(dsn(), 1)
  cleanupUsers(database, "t070-%")
  discard database.execUpdate("delete from auth.oauth_flows")
  startStub()
  let oidc = OidcConfig(
    authorizeUrl: stubBase & "/authorize",
    tokenUrl: stubBase & "/token",
    jwksUrl: stubBase & "/jwks",
    issuer: stubBase,
    clientId: clientId,
    redirectUri: redirectUri)
  startServer(newApp(database, oidc, loadKeyring(keysJson, "1"),
    newConfigCache(database)), port, baseUrl)

proc startFlow(returnTo: string): tuple[state, nonce: string] =
  let response = call(baseUrl, HttpPost, "/auth/start",
    body = $ %*{"returnTo": returnTo})
  doAssert response.status == 200, response.body
  check response.header("Set-Cookie").contains("majadu_auth_flow=")
  let url = response.json["authorizeUrl"].getStr()
  (queryParam(url, "state"), queryParam(url, "nonce"))

proc stubCode(state, nonce, subject, email: string): string =
  let client = newHttpClient(timeout = 5000, maxRedirects = 0)
  defer: client.close()
  let url = stubBase & "/authorize?redirect_uri=" & encodeUrl(redirectUri) &
    "&state=" & encodeUrl(state) & "&nonce=" & encodeUrl(nonce) &
    "&sub=" & encodeUrl(subject) & "&login_hint=" & encodeUrl(email)
  let response = client.get(url)
  doAssert response.code.int == 302, response.body
  queryParam(response.headers["Location"], "code")

proc callback(state, code: string, withCookie = true): HttpResult =
  # The flow is bound to the browser that started it; `withCookie = false` is
  # what a callback handed to a victim's browser looks like.
  var headers: seq[(string, string)] = @[]
  if withCookie:
    headers.add(("Cookie", "majadu_auth_flow=" & sha256Hex(state)))
  call(baseUrl, HttpGet,
    "/auth/callback?code=" & encodeUrl(code) & "&state=" & encodeUrl(state),
    extra = headers, maxRedirects = 0)

proc insertFlow(state, nonce, returnTo: string, expired = false) =
  let keyring = loadKeyring(keysJson, "1")
  let (_, encrypted) = encryptWith(keyring, "verifier-" & state, state)
  let minutes = if expired: -5 else: 10
  discard database.execUpdate(
    """insert into auth.oauth_flows
         (state_hash, nonce_hash, code_verifier_enc, return_to, expires_at)
       values (decode($1, 'hex'), decode($2, 'hex'), decode($3, 'hex'), $4,
               now() + make_interval(mins => $5))""",
    @[textParam(sha256Hex(state)), textParam(sha256Hex(nonce)),
      textParam(bytesHex(encrypted)), textParam(returnTo),
      intParam(minutes.int64)])

requireDatabase()

bootstrap()

suite "security: OIDC replay":
  test "v1-red/v2-green: a consumed flow cannot be replayed":
    let (state, nonce) = startFlow("/sessions")
    check state.len > 0
    let code = stubCode(state, nonce, "t070-sub-1", "t070-1@example.com")

    let first = callback(state, code)
    expectStatus(first, 302)
    check first.header("Location") == "/sessions"
    check first.header("Set-Cookie").contains("majadu_session=")

    let replay = callback(state, code)
    expectProblem(replay, 400, "INVALID_STATE")
    check replay.header("Set-Cookie").len == 0

    let sessions = database.queryOne(
      """select count(*)::int as n from account.sessions
         where user_id = (select id from platform.user
                          where google_sub = 't070-sub-1')""")
    check sessions.get.get("n") == "1"

  test "v1-red/v2-green: a signed id_token with the wrong nonce is rejected":
    let (state, nonce) = startFlow("/sessions")
    let code = stubCode(state, "not-the-flow-nonce", "t070-sub-2",
      "t070-2@example.com")
    let rejected = callback(state, code)
    expectProblem(rejected, 401, "NONCE_MISMATCH")
    check rejected.header("Set-Cookie").len == 0
    # The flow was consumed before the nonce was checked: no free retry.
    expectProblem(callback(state, code), 400, "INVALID_STATE")

  test "a callback from another browser cannot use the flow":
    let (state, nonce) = startFlow("/sessions")
    let code = stubCode(state, nonce, "t070-sub-3", "t070-3@example.com")
    # A login-CSRF attempt: the attacker's callback URL opened by someone whose
    # browser has no marker for this flow.
    let foreign = callback(state, code, withCookie = false)
    expectProblem(foreign, 400, "INVALID_STATE")
    check foreign.header("Set-Cookie").len == 0
    # The flow was not burned by the refusal, so the real browser can still use it.
    expectStatus(callback(state, code), 302)

  test "an expired flow is rejected":
    let state = randomHex(32)
    let nonce = randomHex(32)
    insertFlow(state, nonce, "/sessions", expired = true)
    let code = stubCode(state, nonce, "t070-sub-3", "t070-3@example.com")
    expectProblem(callback(state, code), 400, "INVALID_STATE")

  test "v1-red/v2-green: the callback revalidates return_to":
    # A row written outside `start` must still never become an off-site
    # Location: the callback validates what it reads from the database.
    var index = 0
    for target in ["//evil", "/\\evil", "%2F%2Evil", "https://evil",
                   "/%2F%2Fevil"]:
      inc index
      let state = randomHex(32)
      let nonce = randomHex(32)
      insertFlow(state, nonce, target)
      let code = stubCode(state, nonce, "t070-sub-off-" & $index,
        "t070-off-" & $index & "@example.com")
      let response = callback(state, code)
      expectStatus(response, 302)
      checkpoint("Location for " & target)
      check response.header("Location") == "/"
      check not response.header("Location").startsWith("//")
      check not response.header("Location").contains("evil")

  test "a stored same-origin path survives the callback":
    let state = randomHex(32)
    let nonce = randomHex(32)
    insertFlow(state, nonce, "/sessions/42")
    let code = stubCode(state, nonce, "t070-sub-ok", "t070-ok@example.com")
    let response = callback(state, code)
    expectStatus(response, 302)
    check response.header("Location") == "/sessions/42"

proc auditCount(action: string): int =
  parseInt(database.queryOne(
    """select count(*)::int as n from account.audit where action = $1""",
    @[textParam(action)]).get.get("n"))

suite "security: auth audit":
  test "a successful login leaves exactly one audit row":
    let (state, nonce) = startFlow("/sessions")
    let code = stubCode(state, nonce, "t070-audit-1",
      "t070-audit-1@example.com")
    let before = auditCount("auth.login")
    expectStatus(callback(state, code), 302)
    check auditCount("auth.login") == before + 1
    let row = database.queryOne(
      """select a.actor_id::text as actor_id, a.community_id,
                a.actor_role, a.result
         from account.audit a
         join platform.user u on u.id = a.actor_id
         where u.google_sub = 't070-audit-1' and a.action = 'auth.login'
         order by a.occurred_at desc limit 1""")
    check row.isSome
    check row.get.get("result") == "allow"
    check row.get.get("actor_role") == "member"
    # A login belongs to no community, so the row carries none.
    check row.get["community_id"].isNone

  test "a rejected id token leaves exactly one audit row":
    let (state, nonce) = startFlow("/sessions")
    let code = stubCode(state, "not-the-flow-nonce", "t070-audit-2",
      "t070-audit-2@example.com")
    let before = auditCount("auth.login.rejected")
    expectProblem(callback(state, code), 401, "NONCE_MISMATCH")
    check auditCount("auth.login.rejected") == before + 1
    let row = database.queryOne(
      """select actor_id, reason, target_kind, target_id
         from account.audit where action = 'auth.login.rejected'
         order by occurred_at desc limit 1""")
    check row.isSome
    # The caller is unknown and the row keeps no token, nonce or address.
    check row.get["actor_id"].isNone
    check row.get.get("reason") == "nonce mismatch"
    check row.get.get("target_kind") == ""
    check row.get.get("target_id") == ""
