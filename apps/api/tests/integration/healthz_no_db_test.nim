## BE-04: the liveness probe is a process check. The app below owns a `Db`
## with no pool at all, which is the same condition as a stopped PostgreSQL:
## any config read or query on the request path would answer 500 or wait.
import std/unittest
import db/db
import account/infrastructure/oidc
import platform/config/store
import share/crypto
import ../../src/app
import ../http_support

let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)

# An empty pool: acquireConn would wait or raise, so reaching it would fail the
# test instead of being hidden behind a slow 503.
let probeApp = newApp(Db(), OidcConfig(), loadKeyring(keysJson, "1"), ConfigCache())

startServer(probeApp, port, baseUrl)

suite "healthz without a database":
  test "answers 200 with no database connection at all":
    let response = call(baseUrl, HttpGet, "/healthz")
    expectStatus(response, 200)
    check response.body == """{"status":"ok"}"""

  test "400 probe requests never answer 429":
    for _ in 0 ..< 400:
      let response = call(baseUrl, HttpGet, "/healthz")
      expectStatus(response, 200)
