## ISO-17: the login has to work when the SPA is served from the fallback
## origin, not only from the Vercel host. The fallback is a real hostname, so the
## redirect URI is `https://` — which makes every cookie `Secure`. This suite
## drives the whole flow on that configuration: `loadOidcConfig` reads the
## fallback origin from the environment, the authorize URL carries it verbatim,
## the stub hands the code back to it, the callback sets a `Secure` session
## cookie, and the loopback client carries that cookie back itself instead of
## lowering `MAJADU_COOKIE_SECURE`.
##
## The cookie is carried by hand because a plain HTTP client drops a `Secure`
## cookie over loopback; that is exactly the gap this suite closes without
## weakening the flag that produced it.

import std/[exitprocs, httpclient, json, os, osproc, strutils, unittest, uri]
import db/db
import sha256
import waiters
import ../../../src/app
import account/infrastructure/oidc
import platform/config/store
import share/crypto
import ../../http_support

let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  stubPort = 18178
  stubBase = "http://127.0.0.1:" & $stubPort
  clientId = "iso17-client"
  ## The static fallback origin the repository documents, not a loopback stand
  ## in: the point is that the exact string registered at the provider travels
  ## into the authorize URL.
  fallbackOrigin = "https://majadu.qouver.com"
  fallbackRedirect = fallbackOrigin & "/api/auth/callback"
  keysJson = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"""

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
  result = getTempDir() / "oidc-stub-iso17"
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
  let binary = ensureStub()
  putEnv("OIDC_STUB_PORT", $stubPort)
  putEnv("OIDC_STUB_ISSUER", stubBase)
  putEnv("OIDC_STUB_CLIENT_ID", clientId)
  # The guard stays strict everywhere else; this suite is the one that proves
  # the fallback host is a legitimate callback.
  putEnv("OIDC_STUB_ALLOWED_REDIRECT_HOSTS", "majadu.qouver.com")
  stubProcess = startProcess(binary, workingDir = repoRoot(), args = [])
  addExitProc(stopStub)
  waitForHttp(stubBase & "/healthz")

proc bootstrap() =
  database = openDb(dsn(), 1)
  cleanupUsers(database, "iso17-%")
  discard database.execUpdate("delete from auth.oauth_flows")
  startStub()
  # The configuration is read the way the binary reads it: environment in, no
  # hand-built OidcConfig. If the fallback origin ever stops reaching the
  # authorize URL, this suite fails at the source.
  putEnv("OIDC_AUTHORIZE_URL", stubBase & "/authorize")
  putEnv("OIDC_TOKEN_URL", stubBase & "/token")
  putEnv("OIDC_JWKS_URL", stubBase & "/jwks")
  putEnv("OIDC_ISSUER", stubBase)
  putEnv("OIDC_CLIENT_ID", clientId)
  putEnv("OIDC_CLIENT_SECRET", "iso17-secret")
  putEnv("OIDC_REDIRECT_URI", fallbackRedirect)
  delEnv("MAJADU_COOKIE_SECURE")
  let oidc = loadOidcConfig()
  doAssert oidc.redirectUri == fallbackRedirect
  startServer(newApp(database, oidc, loadKeyring(keysJson, "1"),
    newConfigCache(database)), port, baseUrl)

proc cookieValue(setCookie, name: string): string =
  for part in setCookie.split(';'):
    let trimmed = part.strip()
    if trimmed.startsWith(name & "="):
      return trimmed[name.len + 1 .. ^1]
  ""

proc stubCode(state, nonce: string): string =
  let client = newHttpClient(timeout = 5000, maxRedirects = 0)
  defer: client.close()
  let url = stubBase & "/authorize?redirect_uri=" & encodeUrl(fallbackRedirect) &
    "&state=" & encodeUrl(state) & "&nonce=" & encodeUrl(nonce) &
    "&sub=" & encodeUrl("iso17-sub-1") &
    "&login_hint=" & encodeUrl("iso17-1@example.com")
  let response = client.get(url)
  doAssert response.code.int == 302, response.body
  check response.headers["Location"].startsWith(fallbackRedirect & "?code=")
  queryParam(response.headers["Location"], "code")

requireDatabase()

bootstrap()

suite "security: login on the fallback origin":
  test "the fallback origin is the redirect_uri the provider sees":
    let response = call(baseUrl, HttpPost, "/auth/start",
      body = """{"returnTo":"/sessions"}""")
    expectStatus(response, 200)
    let authorizeUrl = response.json["authorizeUrl"].getStr()
    check authorizeUrl.startsWith(stubBase & "/authorize")
    check queryParam(authorizeUrl, "redirect_uri") == fallbackRedirect
    check queryParam(authorizeUrl, "client_id") == clientId
    check queryParam(authorizeUrl, "state").len > 0
    check queryParam(authorizeUrl, "nonce").len > 0
    # https redirect URI, so the flow cookie is Secure without any flag.
    let flowCookie = response.header("Set-Cookie")
    check flowCookie.contains("majadu_auth_flow=")
    check flowCookie.contains("Secure")

  test "start, stub, callback and session all work on that origin":
    let start = call(baseUrl, HttpPost, "/auth/start",
      body = """{"returnTo":"/sessions"}""")
    expectStatus(start, 200)
    let authorizeUrl = start.json["authorizeUrl"].getStr()
    let state = queryParam(authorizeUrl, "state")
    let nonce = queryParam(authorizeUrl, "nonce")
    let code = stubCode(state, nonce)

    let callback = call(baseUrl, HttpGet,
      "/auth/callback?code=" & encodeUrl(code) & "&state=" & encodeUrl(state),
      extra = [("Cookie", "majadu_auth_flow=" & sha256Hex(state))],
      maxRedirects = 0)
    expectStatus(callback, 302)
    check callback.header("Location") == "/sessions"
    let sessionCookie = callback.header("Set-Cookie")
    check sessionCookie.contains("majadu_session=")
    check sessionCookie.contains("Secure")
    let session = cookieValue(sessionCookie, "majadu_session")
    check session.len > 0

    # Carried by hand: a Secure cookie would be dropped over plain loopback by
    # the client, and turning the flag off is the one thing this must not do.
    let me = call(baseUrl, HttpGet, "/auth/me", cookie = session)
    expectStatus(me, 200)
    check me.json["id"].getStr().len > 0
