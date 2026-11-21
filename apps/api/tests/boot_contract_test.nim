## The boot contract: what a misconfigured process refuses, and with which
## message. `main()` cannot run under a test, so the two refusals it relies on
## (`loadOidcConfig`, `secureCookies`) and the boot order (`bootHandler`) are
## asserted here instead of on a live port.

import std/[algorithm, json, net, os, strutils, unittest]
import ../src/app
import ../src/main
import ../src/server
import account/infrastructure/oidc
import build_info
import db/db
import platform/config/store
import share/crypto

const oidcVars = [
  "OIDC_AUTHORIZE_URL", "OIDC_TOKEN_URL", "OIDC_JWKS_URL", "OIDC_ISSUER",
  "OIDC_CLIENT_ID", "OIDC_CLIENT_SECRET", "OIDC_REDIRECT_URI",
]

proc withOidcEnv(clientId, redirect: string, work: proc()) =
  ## Every OIDC variable is cleared first, so a value left in the developer's
  ## shell cannot make a default assertion pass by accident.
  for name in oidcVars:
    delEnv(name)
  putEnv("OIDC_CLIENT_ID", clientId)
  putEnv("OIDC_REDIRECT_URI", redirect)
  try:
    work()
  finally:
    for name in oidcVars:
      delEnv(name)

proc cookieSecureFor(redirect: string): bool =
  ## `secureCookies` is private. Its only product is `App.cookieSecure`, and
  ## `newApp` touches no database: it stores the handle and builds the limiter
  ## and the hub.
  newApp(Db(), OidcConfig(redirectUri: redirect), Keyring(),
    ConfigCache()).cookieSecure

proc messageOf(work: proc()): string =
  try:
    work()
  except ValueError as error:
    return error.msg

suite "loadOidcConfig":
  test "an empty client id or redirect uri refuses to start":
    withOidcEnv("", "https://majadu.test/api/auth/callback", proc() =
      expect ValueError:
        discard loadOidcConfig())
    withOidcEnv("client-1", "", proc() =
      expect ValueError:
        discard loadOidcConfig())

  test "the provider urls fall back to Google and the identifiers do not":
    withOidcEnv("client-1", "https://majadu.test/api/auth/callback", proc() =
      let config = loadOidcConfig()
      check config.authorizeUrl == "https://accounts.google.com/o/oauth2/v2/auth"
      check config.tokenUrl == "https://oauth2.googleapis.com/token"
      check config.jwksUrl == "https://www.googleapis.com/oauth2/v3/certs"
      check config.issuer == "https://accounts.google.com"
      check config.clientId == "client-1"
      check config.clientSecret == ""
      check config.redirectUri == "https://majadu.test/api/auth/callback")

  test "configured urls win over the defaults":
    withOidcEnv("client-1", "https://majadu.test/api/auth/callback", proc() =
      putEnv("OIDC_AUTHORIZE_URL", "https://id.test/authorize")
      putEnv("OIDC_TOKEN_URL", "https://id.test/token")
      putEnv("OIDC_JWKS_URL", "https://id.test/keys")
      putEnv("OIDC_ISSUER", "https://id.test")
      let config = loadOidcConfig()
      check config.authorizeUrl == "https://id.test/authorize"
      check config.tokenUrl == "https://id.test/token"
      check config.jwksUrl == "https://id.test/keys"
      check config.issuer == "https://id.test")

suite "authorizeUrl":
  test "every parameter is carried and encoded":
    let config = OidcConfig(authorizeUrl: "https://id.test/authorize",
      clientId: "client 1", redirectUri: "https://app.test/cb?x=1")
    let url = authorizeUrl(config, "st ate", "non ce", "chal+enge")
    check url.startsWith("https://id.test/authorize?")
    check url.contains("client_id=client+1")
    check url.contains("redirect_uri=https%3A%2F%2Fapp.test%2Fcb%3Fx%3D1")
    check url.contains("response_type=code")
    check url.contains("scope=openid%20email%20profile")
    check url.contains("state=st+ate")
    check url.contains("nonce=non+ce")
    check url.contains("code_challenge=chal%2Benge")
    check url.contains("code_challenge_method=S256")

  test "an authorize url that already has a query keeps one question mark":
    let config = OidcConfig(authorizeUrl: "https://id.test/authorize?prompt=login",
      clientId: "c", redirectUri: "https://app.test/cb")
    let url = authorizeUrl(config, "s", "n", "c")
    check url.startsWith("https://id.test/authorize?prompt=login&")
    check url.count('?') == 1

suite "secureCookies":
  test "the redirect uri decides when no flag is set":
    delEnv("MAJADU_COOKIE_SECURE")
    check cookieSecureFor("https://majadu.test/api/auth/callback") == true
    check cookieSecureFor("http://127.0.0.1:5173/api/auth/callback") == false

  test "an explicit 1 turns the cookie secure over plain http":
    putEnv("MAJADU_COOKIE_SECURE", "1")
    check cookieSecureFor("http://127.0.0.1:5173/api/auth/callback") == true
    delEnv("MAJADU_COOKIE_SECURE")

  test "0 over plain http is allowed and 0 over https refuses to start":
    putEnv("MAJADU_COOKIE_SECURE", "0")
    try:
      check cookieSecureFor("http://127.0.0.1:5173/api/auth/callback") == false
      let message = messageOf(proc() =
        discard cookieSecureFor("https://majadu.test/api/auth/callback"))
      check message.contains("MAJADU_COOKIE_SECURE=0")
    finally:
      delEnv("MAJADU_COOKIE_SECURE")

suite "buildInfoJson":
  test "the startup log and the version route name the same fields":
    let info = parseJson(buildInfoJson(4))
    var keys: seq[string] = @[]
    for key in info.keys:
      keys.add(key)
    keys.sort()
    check keys == @["commit", "version", "worker_threads"]
    check info["version"].getStr() == AppVersion
    check info["commit"].getStr() == GitCommit
    check info["worker_threads"].getInt() == 4

  test "the version route is built from the same two defines (source guard)":
    ## `/version` is served by `app.nim`, and reaching it needs a bound port, so
    ## this case guards the two names in the source instead. It is a text
    ## assertion on purpose: `buildInfoJson` above proves the values, and this
    ## proves the route has not drifted to a third name.
    let source = readFile(currentSourcePath().parentDir / "../src/app.nim")
    check source.contains(""""version": appVersion""")
    check source.contains(""""commit": appCommit""")

suite "bootHandler":
  test "test routes beside MAJADU_ENV=prod refuse before any connection":
    # SEC-13: `MAJADU_TEST_ROUTES=1` replaces the whole router with a stub that
    # answers `/healthz` 200 and everything else 404, `/readyz` included, so a
    # production process must refuse it before it opens the pool.
    let previousEnv = getEnv("MAJADU_ENV")
    let previousDsn = getEnv("MAJADU_PG_DSN")
    delEnv("MAJADU_PG_DSN")
    putEnv("MAJADU_ENV", "prod")
    try:
      let message = messageOf(proc() =
        discard bootHandler(ServerConfig(port: Port(8080), testRoutes: true), 2))
      check message.contains("MAJADU_TEST_ROUTES")
      # The refusal is about the flag, not the missing DSN: the stub is checked
      # first so this case cannot pass on an unrelated error.
      check not message.contains("MAJADU_PG_DSN")
    finally:
      if previousEnv.len > 0: putEnv("MAJADU_ENV", previousEnv)
      else: delEnv("MAJADU_ENV")
      if previousDsn.len > 0: putEnv("MAJADU_PG_DSN", previousDsn)

  test "a missing DSN refuses before any connection is attempted":
    let previous = getEnv("MAJADU_PG_DSN")
    delEnv("MAJADU_PG_DSN")
    try:
      let message = messageOf(proc() =
        discard bootHandler(ServerConfig(port: Port(8080)), 2))
      check message == "MAJADU_PG_DSN is required"
    finally:
      if previous.len > 0:
        putEnv("MAJADU_PG_DSN", previous)

  test "production with no trusted proxy refuses before connecting":
    # BE-03: with an empty trusted-proxy list every anonymous caller shares the
    # CDN address, so a production process must not start that way.
    let previousDsn = getEnv("MAJADU_PG_DSN")
    let previousEnv = getEnv("MAJADU_ENV")
    let previousTrusted = getEnv("MAJADU_TRUSTED_PROXIES")
    putEnv("MAJADU_PG_DSN", "postgresql://nobody@127.0.0.1:1/never")
    putEnv("MAJADU_ENV", "prod")
    putEnv("MAJADU_TRUSTED_PROXIES", "")
    try:
      let message = messageOf(proc() =
        discard bootHandler(ServerConfig(port: Port(8080)), 2))
      check message.contains("MAJADU_TRUSTED_PROXIES")
    finally:
      if previousDsn.len > 0: putEnv("MAJADU_PG_DSN", previousDsn)
      else: delEnv("MAJADU_PG_DSN")
      if previousEnv.len > 0: putEnv("MAJADU_ENV", previousEnv)
      else: delEnv("MAJADU_ENV")
      if previousTrusted.len > 0:
        putEnv("MAJADU_TRUSTED_PROXIES", previousTrusted)
      else:
        delEnv("MAJADU_TRUSTED_PROXIES")

suite "process sizing and drain exit":
  test "the worker count is above the core count, so one slow read is not half":
    ## REL-BE-06: `max(countProcessors(), 2)` gave the 2 vCPU host two workers,
    ## and one 15s statement timeout took half the request capacity. Both the
    ## thread count and the pool size come from the same derivation now.
    check apiWorkerThreads(2) > 2
    check apiWorkerThreads(1) > 1
    check apiWorkerThreads(4) > 4
    # A container that reports no CPU at all still gets a serving pool.
    check apiWorkerThreads(0) > 0

  test "the pool is the worker count plus the headroom, from one derivation":
    ## REL-BE-06: the thread count and the pool size must not drift, so both
    ## come from this module. One connection per worker would deadlock a `tx`
    ## body that calls a `Db` helper.
    check poolSizeFor(2) == 2 + 2
    check poolSizeFor(apiWorkerThreads(2)) == apiWorkerThreads(2) + 2
    check poolSizeFor(apiWorkerThreads(2)) > apiWorkerThreads(2)

  test "the drain overrun exits 0, so a stop is not a crash":
    ## REL-BE-08: `Restart=on-failure` plus `StartLimitBurst=5` turned five
    ## overrun drains into a dead unit. The hard bound is reached only after a
    ## signal asked for the stop, so it must not read as a failure.
    check drainOverrunStatus() == 0

suite "readiness under a busy pool":
  ## REL-BE-03: the deploy gate polls `/readyz` for 60s. A busy pool is capacity,
  ## not readiness, so it must not roll a good release back; a database that is
  ## actually failing still keeps the process out of the rotation.
  test "a pool timeout contributes no refusal":
    let busy = newException(DbPoolTimeout, "no connection within 5000ms")
    check readinessDetail(busy) == ""

  test "any other database failure is still unreachable":
    let down = newException(DbError, "could not connect to server")
    check readinessDetail(down) == "database is unreachable"
    # A `DbError` carrying a SQLSTATE is the same branch: the pool is fine and
    # the server is not, which is exactly the case `/readyz` exists for.
    let cancelled = newException(DbError, "canceling statement due to timeout")
    cancelled.sqlState = "57014"
    check readinessDetail(cancelled) == "database is unreachable"