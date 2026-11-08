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