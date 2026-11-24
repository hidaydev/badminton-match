## The login that grants a membership outside the last community by slug.
##
## `finishAuth` writes one `community.join` audit row per grant it created. The
## grants themselves come from `acceptPendingForEmail`, which loops the root
## table and claims one community at a time, and `set_config(..., false)` is
## session-scoped: when that loop returns, the connection still declares the last
## community it touched, not the grant's. Under the 0061 policy set
## `account.audit`'s check is `community_id is null or community_id =
## tenant_id()`, so a row for any other community is refused, `statusForSqlState`
## turns 42501 into a 500, the transaction rolls back the membership rows, and
## the person cannot log in at all.
##
## The victim is the first admin of every new community, whose invite
## `createCommunity` writes. The fixture therefore puts one pending invite in a
## community that does NOT sort last, which is the only arrangement that shows
## the bug: with the invite in the last community the setting happens to match.
##
## Runs as `bm2_app` through the real routes, on a database that must carry the
## policy set. A green run there is evidence; a green run without the policies is
## not, so the precondition is an assertion and not a skip.

import std/[exitprocs, httpclient, json, options, os, osproc, strutils, unittest,
            uri]
import db/db
import sha256
import waiters
import account/infrastructure/oidc
import platform/config/store
import share/crypto
import tests/fixtures
import ../http_support
import ../../src/app

const
  ## Keyring beyond the shared fixture key is not needed: this suite only reads
  ## the flow's verifier, it never rotates a key.
  keysJson = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"""

let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  stubPort = 18183
  stubBase = "http://127.0.0.1:" & $stubPort
  clientId = "policy-login-client"
  redirectUri = "http://127.0.0.1:5173/api/auth/callback"

const
  ## `policy-login-a` sorts before `policy-login-z`, and the invite lives in the
  ## first one. The loop therefore ends declaring `-z` while the grant belongs to
  ## `-a`.
  slugGranted = "policy-login-a"
  slugLast = "policy-login-z"
  subject = "policy-login-sub"
  address = "policy-login@example.com"
  appRoleOption = "options=-c%20role%3Dbm2_app"

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
  result = getTempDir() / "oidc-stub-policy-login"
  if fileExists(result):
    return
  let repo = repoRoot()
  let (output, code) = execCmdEx("nim c --hints:off -o:" &
    quoteShell(result) & " " & quoteShell(repo / "tools/oidc-stub/main.nim"),
    workingDir = repo)
  doAssert code == 0, "cannot build the OIDC stub: " & output

proc stopStub() {.noconv.} =
  if stubProcess != nil:
    try:
      terminate(stubProcess)
    except CatchableError:
      discard

proc startStub() =
  let bin = ensureStub()
  putEnv("OIDC_STUB_PORT", $stubPort)
  putEnv("OIDC_STUB_ISSUER", stubBase)
  putEnv("OIDC_STUB_CLIENT_ID", clientId)
  stubProcess = startProcess(bin, workingDir = repoRoot(), args = [])
  addExitProc(stopStub)
  waitForHttp(stubBase & "/healthz")

proc appDsn(raw: string): string =
  ## The same database reached as the role production uses. `options` has to
  ## respect a query string the caller already put on the DSN.
  let query = raw.find('?')
  let (head, tail) =
    if query >= 0: (raw[0 ..< query], raw[query + 1 .. ^1])
    else: (raw, "")
  if tail.len > 0: head & "?" & tail & "&" & appRoleOption
  else: head & "?" & appRoleOption

proc startFlow(): tuple[state, nonce: string] =
  let response = call(baseUrl, HttpPost, "/auth/start",
    body = """{"returnTo":"/"}""")
  doAssert response.status == 200, response.body
  let url = response.json["authorizeUrl"].getStr()
  (queryParam(url, "state"), queryParam(url, "nonce"))

proc stubCode(state, nonce: string): string =
  let client = newHttpClient(timeout = 5000, maxRedirects = 0)
  defer: client.close()
  let url = stubBase & "/authorize?redirect_uri=" & encodeUrl(redirectUri) &
    "&state=" & encodeUrl(state) & "&nonce=" & encodeUrl(nonce) &
    "&sub=" & encodeUrl(subject) & "&login_hint=" & encodeUrl(address)
  let response = client.get(url)
  doAssert response.code.int == 302, response.body
  queryParam(response.headers["Location"], "code")

proc cleanup() =
  for slug in [slugGranted, slugLast]:
    purgeCommunity(database, slug)
  cleanupUsers(database, "policy-login-")
  discard database.execUpdate("delete from auth.oauth_flows")

proc bootstrap() =
  requireDatabase()
  database = openDb(dsn(), 1)
  let policiesOn = database.queryOne(
    """select count(*)::int as n from pg_policies
       where schemaname = 'account' and tablename = 'audit'""").get.getInt("n") > 0
  doAssert policiesOn, "policy_login_audit needs a database with the 0061 " &
    "policy set; run it in the job that applies 0061 (./task policy-test)"
  cleanup()
  let granted = newCommunity(database, slugGranted, "Policy Login Granted")
  discard newCommunity(database, slugLast, "Policy Login Last")
  # One pending first-admin invite, in the community that does not sort last.
  discard database.execUpdate(
    """insert into community.invite (community_id, token_hash, email_hash, role)
       values ($1::uuid, sha256('policy-login-token'::bytea), $2, 'admin')""",
    @[textParam(granted), textParam(sha256Hex(address))])
  startStub()
  let oidc = OidcConfig(
    authorizeUrl: stubBase & "/authorize",
    tokenUrl: stubBase & "/token",
    jwksUrl: stubBase & "/jwks",
    issuer: stubBase,
    clientId: clientId,
    redirectUri: redirectUri)
  # The app pool reaches the database as `bm2_app`, which is the role the policy
  # set constrains; `newTestApp` would build an empty OidcConfig and the exchange
  # would go to no provider at all.
  let appPool = openDb(appDsn(dsn()), 4)
  startServer(newApp(appPool, oidc, loadKeyring(keysJson, "1"),
    newConfigCache(appPool)), port, baseUrl)

bootstrap()

suite "login grants outside the last community":
  test "the login succeeds and audits the grant in its own community":
    # 302 is the whole point: before the fix this answers 500, the membership
    # rows roll back, and the first admin of a new community cannot get in.
    let (state, nonce) = startFlow()
    check state.len > 0
    let response = call(baseUrl, HttpGet,
      "/auth/callback?code=" & encodeUrl(stubCode(state, nonce)) &
        "&state=" & encodeUrl(state),
      extra = @[("Cookie", "majadu_auth_flow=" & sha256Hex(state))],
      maxRedirects = 0)
    expectStatus(response, 302)
    check response.header("Set-Cookie").contains("majadu_session=")
    # The grant landed, in the community the invitation named.
    let granted = database.queryOne(
      """select count(*)::int as n from community.membership m
         join platform.community c on c.id = m.community_id
         join platform.user u on u.id = m.user_id
         where c.slug = $1 and u.google_sub = $2""",
      @[textParam(slugGranted), textParam(subject)]).get.getInt("n")
    check granted == 1
    # And the evidence names that community, not the last one the loop touched.
    let audited = database.queryOne(
      """select count(*)::int as n from account.audit a
         join platform.community c on c.id = a.community_id
         join platform.user u on u.id = a.actor_id
         where a.action = 'community.join' and c.slug = $1
           and u.google_sub = $2""",
      @[textParam(slugGranted), textParam(subject)]).get.getInt("n")
    check audited == 1

  teardown:
    cleanup()
