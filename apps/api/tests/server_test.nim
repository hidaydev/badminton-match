import std/[json, os, strutils, unittest]
import ../src/server
import ../src/quota_route
import clock

suite "process contract":
  test "MAJADU_PORT is required":
    delEnv("MAJADU_PORT")
    expect ValueError:
      discard loadConfig()

  test "MAJADU_PORT must be numeric":
    putEnv("MAJADU_PORT", "abc")
    putEnv("MAJADU_DRAIN_MS", "0")
    expect ValueError:
      discard loadConfig()

  test "MAJADU_PORT must fit in 16 bits":
    putEnv("MAJADU_PORT", "70000")
    putEnv("MAJADU_DRAIN_MS", "0")
    expect ValueError:
      discard loadConfig()

  test "MAJADU_DRAIN_MS is required":
    putEnv("MAJADU_PORT", "8080")
    delEnv("MAJADU_DRAIN_MS")
    expect ValueError:
      discard loadConfig()

  test "accepts a valid contract":
    putEnv("MAJADU_PORT", "8080")
    putEnv("MAJADU_DRAIN_MS", "0")
    delEnv("MAJADU_SHUTDOWN_TIMEOUT_MS")
    delEnv("MAJADU_METRICS_PORT")
    let config = loadConfig()
    check config.port.int == 8080
    check config.drainMs == 0
    check config.shutdownTimeoutMs == 30000
    check config.testRoutes == false
    check config.metricsPort == 0

  test "the skeleton flag refuses a release configuration":
    # SQ-04: MAJADU_TEST_ROUTES swaps the whole API for the stub, so an https
    # redirect (or an explicit production signal) must stop the process instead
    # of leaving a healthy-looking 404.
    putEnv("MAJADU_PORT", "8080")
    putEnv("MAJADU_DRAIN_MS", "0")
    putEnv("MAJADU_TEST_ROUTES", "1")
    putEnv("OIDC_REDIRECT_URI", "https://majadu.test/api/auth/callback")
    delEnv("MAJADU_METRICS_PORT")
    try:
      expect ValueError:
        discard loadConfig()
    finally:
      delEnv("MAJADU_TEST_ROUTES")
      delEnv("OIDC_REDIRECT_URI")

  test "the skeleton flag also refuses a secure cookie over plain http":
    putEnv("MAJADU_PORT", "8080")
    putEnv("MAJADU_DRAIN_MS", "0")
    putEnv("MAJADU_TEST_ROUTES", "1")
    putEnv("OIDC_REDIRECT_URI", "http://127.0.0.1:5173/api/auth/callback")
    putEnv("MAJADU_COOKIE_SECURE", "1")
    delEnv("MAJADU_ENV")
    try:
      expect ValueError:
        discard loadConfig()
    finally:
      delEnv("MAJADU_TEST_ROUTES")
      delEnv("OIDC_REDIRECT_URI")
      delEnv("MAJADU_COOKIE_SECURE")

  test "the skeleton flag refuses MAJADU_ENV=prod":
    putEnv("MAJADU_PORT", "8080")
    putEnv("MAJADU_DRAIN_MS", "0")
    putEnv("MAJADU_TEST_ROUTES", "1")
    putEnv("OIDC_REDIRECT_URI", "http://127.0.0.1:5173/api/auth/callback")
    delEnv("MAJADU_COOKIE_SECURE")
    putEnv("MAJADU_ENV", "prod")
    try:
      expect ValueError:
        discard loadConfig()
    finally:
      delEnv("MAJADU_TEST_ROUTES")
      delEnv("OIDC_REDIRECT_URI")
      delEnv("MAJADU_ENV")

  test "a pinned clock refuses MAJADU_ENV=prod":
    # A pinned Nim clock beside a real PostgreSQL clock breaks JWT expiry,
    # rate-limit windows and flow TTL comparisons without any error, so the
    # two switches are refused together instead of being trusted to the file.
    putEnv("MAJADU_PORT", "8080")
    putEnv("MAJADU_DRAIN_MS", "0")
    putEnv("MAJADU_NOW", "2026-11-03T12:00:00Z")
    putEnv("MAJADU_ENV", "prod")
    delEnv("MAJADU_TEST_ROUTES")
    delEnv("OIDC_REDIRECT_URI")
    delEnv("MAJADU_COOKIE_SECURE")
    delEnv("MAJADU_METRICS_PORT")
    try:
      expect ValueError:
        discard loadConfig()
    finally:
      delEnv("MAJADU_NOW")
      delEnv("MAJADU_ENV")

  test "a pinned clock alone is accepted and reported by clockPinned":
    putEnv("MAJADU_PORT", "8080")
    putEnv("MAJADU_DRAIN_MS", "0")
    putEnv("MAJADU_NOW", "2026-11-03T12:00:00Z")
    delEnv("MAJADU_ENV")
    delEnv("MAJADU_TEST_ROUTES")
    delEnv("OIDC_REDIRECT_URI")
    delEnv("MAJADU_COOKIE_SECURE")
    delEnv("MAJADU_METRICS_PORT")
    try:
      check clockPinned()
      discard loadConfig()
    finally:
      delEnv("MAJADU_NOW")
    check not clockPinned()

suite "metrics listener":
  test "is off unless a port is configured":
    delEnv("MAJADU_METRICS_PORT")
    check loadMetricsPort() == 0

  test "a bad port refuses to start instead of hiding the listener":
    putEnv("MAJADU_METRICS_PORT", "not-a-port")
    expect ValueError:
      discard loadMetricsPort()
    putEnv("MAJADU_METRICS_PORT", "70000")
    expect ValueError:
      discard loadMetricsPort()
    delEnv("MAJADU_METRICS_PORT")

  test "counts the route template, never the raw path":
    discard recordResponse("GET", "/c/acme/clubs", 200)
    check metricsText().contains(
      """route="/c/{slug}/clubs",status="200"} 1""")

  test "unmatched paths share one bucket so a scanner cannot mint series":
    discard recordResponse("GET", "/nope/one", 404)
    discard recordResponse("GET", "/nope/two", 404)
    let text = metricsText()
    check text.contains("""method="GET",route="unmatched",status="404"}""")
    check not text.contains("/nope/one")

  test "an explicit quota label survives a 404":
    # `route()` hands the contract shape (or `/unmatched`) to both the limiter
    # and the counter, so a 404 from a matched route must not be renamed here.
    discard recordResponse("GET", "/c/acme/players/missing", 404,
      "/c/{slug}/players/{id}")
    check metricsText().contains(
      """route="/c/{slug}/players/{id}",status="404"}""")

  test "records the request duration in a histogram per route template":
    beginRequest()
    discard recordResponse("GET", "/c/acme/sessions/abc", 200,
      "/c/{slug}/sessions")
    let text = metricsText()
    check text.contains("http_request_duration_seconds_bucket")
    check text.contains(
      """http_request_duration_seconds_bucket{route="/c/{slug}/sessions",le="+Inf"} 1""")
    check text.contains(
      """http_request_duration_seconds_sum{route="/c/{slug}/sessions"}""")
    check text.contains(
      """http_request_duration_seconds_count{route="/c/{slug}/sessions"} 1""")

  test "a thousand junk session ids leave one series, not a thousand":
    ## SEC-15: the label is the matched contract shape, never the raw path, so a
    ## member naming a session id that does not exist cannot grow the registry
    ## one counter at a time. The table length is what this case checks: the
    ## series count for PATCH must grow by at most one after the loop.
    proc patchSeries(): int =
      for line in metricsText().splitLines():
        if line.startsWith("""http_requests_total{method="PATCH"""):
          inc result
    let before = patchSeries()
    for index in 0 ..< 1000:
      let path = "/c/x/sessions/junk" & $index
      discard recordResponse("PATCH", path, 400, quotaRoute(path))
    let text = metricsText()
    check text.contains(
      """method="PATCH",route="/c/{slug}/sessions/{id}",status="400"}""")
    check not text.contains("junk")
    check patchSeries() - before <= 1

  test "exposes the pool as gauges":
    recordPool(8, 3, 5)
    let text = metricsText()
    check text.contains("db_pool_size 8.0")
    check text.contains("db_pool_available 3.0")
    check text.contains("db_pool_in_use 5.0")

  test "counts how the limiter named the caller":
    recordIdentitySource("cookie")
    recordIdentitySource("header")
    recordIdentitySource("peer")
    let text = metricsText()
    check text.contains("""identity_resolution{source="cookie"}""")
    check text.contains("""identity_resolution{source="header"}""")
    check text.contains("""identity_resolution{source="peer"}""")

suite "healthz":
  test "returns ok without touching the database":
    let outcome = route("/healthz", testRoutes = false)
    check outcome.status == 200
    check outcome.body == """{"status":"ok"}"""

  test "unknown paths are 404":
    let outcome = route("/nope", testRoutes = false)
    check outcome.status == 404

  test "test route is disabled by default":
    let outcome = route("/__test/slow", testRoutes = false)
    check outcome.status == 404

  test "test route is reachable when enabled":
    let outcome = route("/__test/slow", testRoutes = true)
    check outcome.status == 200

  test "the skeleton health names the stub":
    let outcome = route("/healthz", testRoutes = true)
    check outcome.status == 200
    check parseJson(outcome.body)["status"].getStr() == "stub"
