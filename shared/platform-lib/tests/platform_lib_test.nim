import std/[json, options, os, strutils, times, unittest]
import ../clock
import ../context
import ../errors
import ../logger
import ../metrics
import ../sha256
import ../token
import ../uuidv7
import clock_fixture

suite "sha256":
  test "matches the standard vector":
    check sha256Hex("abc") ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

suite "clock":
  test "MAJADU_NOW forces the clock":
    withPinnedClock("2026-11-03T12:00:00Z"):
      check utcNow() ==
        parse("2026-11-03T12:00:00Z", "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())

  test "invalid MAJADU_NOW refuses to start":
    withPinnedClock("2026-11-03 12:00:00"):
      expect ValueError:
        discard utcNow()

  test "withPinnedClock restores the previous value after a raised assertion":
    putEnv("MAJADU_NOW", "2026-01-01T00:00:00Z")
    var raised = false
    try:
      withPinnedClock("2026-11-03T12:00:00Z"):
        doAssert utcNow().monthday == 2, "the pinned day is the third"
    except AssertionDefect:
      raised = true
    check raised
    check getEnv("MAJADU_NOW") == "2026-01-01T00:00:00Z"
    delEnv("MAJADU_NOW")

  test "withPinnedClock removes a value the process did not have":
    delEnv("MAJADU_NOW")
    var raised = false
    try:
      withPinnedClock("2026-11-03T12:00:00Z"):
        doAssert false, "the restore must run anyway"
    except AssertionDefect:
      raised = true
    check raised
    check not existsEnv("MAJADU_NOW")

suite "uuidv7":
  test "sets the version and variant bits":
    let bytes = uuidv7Bytes(1_700_000_000_000)
    check (bytes[6] shr 4) == 7
    check (bytes[8] shr 6) == 2

  test "orders by timestamp":
    check uuidv7(1_700_000_000_000) < uuidv7(1_700_000_001_000)

  test "reads the pinned clock":
    ## MAJADU_NOW pins the timestamp prefix too, so replay ids sort against the
    ## pinned instant instead of the wall clock.
    withPinnedClock("2026-11-03T12:00:00Z"):
      check uuidv7().startsWith("01a1a147-ce00")

suite "token":
  proc ascending(first: int): ByteSource =
    ## A deterministic source so the exact hex can be asserted.
    result = proc(count: int): seq[byte] =
      for index in 0 ..< count:
        result.add(byte(first + index))

  test "newOpaqueToken renders the injected bytes exactly":
    check newOpaqueToken(ascending(0)) ==
      "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

  test "two injected sources produce different tokens":
    check newOpaqueToken(ascending(0)) != newOpaqueToken(ascending(128))

  test "the default source still yields 32 random bytes":
    check newOpaqueToken().len == 64

suite "redaction":
  test "share code path":
    check redact("/s/abc123") == "/s/{code}"

  test "ws ticket query":
    check redact("?ticket=secret") == "?ticket=REDACTED"

  test "ws share path segment":
    check redact("/ws/share/abc123") == "/ws/share/{code}"
    check redact("/ws/share/abc123?x=1") == "/ws/share/{code}?x=1"

  test "auth and cookie headers":
    check redact("Authorization: Bearer xyz") == "Authorization: REDACTED"
    check redact("Cookie: sid=abc") == "Cookie: REDACTED"

  test "email and ip":
    check redact("user@example.com") == "{email}"
    check redact("127.0.0.1") == "{ip}"

  test "ipv6 addresses":
    check redact("::1") == "{ip}"
    check redact("[2001:db8::1]:8080") == "[{ip}]:8080"
    check redact("2001:0db8:85a3:0000:0000:8a2e:0370:7334") == "{ip}"

  test "query secrets":
    check redact("?code=abc123") == "?code=REDACTED"
    check redact("?token=t&x=1") == "?token=REDACTED&x=1"
    check redact("?key=k") == "?key=REDACTED"

  test "timestamps, hashes and routes survive":
    check redact("2026-11-07T12:00:00Z") == "2026-11-07T12:00:00Z"
    check redact("12:00:00") == "12:00:00"
    check redact(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check redact("/c/my-club/sessions/42") == "/c/my-club/sessions/42"
    check redact("?zipcode=12345") == "?zipcode=12345"

  test "log line is one json object":
    let line = renderLog("info", "request", [("path", "/s/abc123"), ("ip", "10.0.0.1")])
    let node = parseJson(line)
    check node["msg"].getStr() == "request"
    check node["path"].getStr() == "/s/{code}"
    check node["ip"].getStr() == "{ip}"

  test "log line keeps a typed field":
    let node = parseJson(renderLog("info", "listening", [],
      [("port", %8080), ("build", %*{"version": "dev"})]))
    check node["port"].getInt() == 8080
    check node["build"]["version"].getStr() == "dev"

suite "metrics":
  test "template route collapses identifiers":
    check templateRoute("/s/abc123") == "/s/{code}"
    check templateRoute("/s/abc123/rankings") == "/s/{code}/rankings"
    check templateRoute("/c/my-club/rankings") == "/c/{slug}/rankings"
    check templateRoute("/c/my-club/sessions/42") == "/c/{slug}/sessions/{id}"
    check templateRoute("/ws/share/abc123") == "/ws/share/{code}"

  test "rejects raw route labels":
    var metrics: Metrics
    expect ValueError:
      metrics.inc("requests", [("route", "/s/abc123")])

  test "renders sorted counters":
    var metrics: Metrics
    metrics.inc("requests", [("route", "/s/{code}")])
    metrics.inc("requests", [("route", "/s/{code}")])
    check metrics.render() == "requests{route=\"/s/{code}\"} 2\n"

suite "errors":
  test "serialises an RFC 9457 shape":
    let node = parseJson(newProblem(404, "NOT_FOUND", "error.notFound").toJson())
    check node["status"].getInt() == 404
    check node["code"].getStr() == "NOT_FOUND"
    check node["i18nKey"].getStr() == "error.notFound"

  test "maps a business code to its translation key":
    check i18nKeyFor("INVALID_BODY") == "error.invalidBody"
    check i18nKeyFor("TOKEN_EXCHANGE_FAILED") == "error.tokenExchangeFailed"
    check i18nKeyFor("NOT_YET_DOCUMENTED") == unknownI18nKey

  test "redacts the detail like a log field":
    let node = parseJson(newProblem(400, "INVALID_EMAIL", "error.invalidEmail",
      "a@b.co from 10.0.0.1").toJson())
    check node["detail"].getStr() == "{email} from {ip}"

suite "context":
  test "carries optional identity without globals":
    let ctx = Ctx(
      requestId: "req-1",
      userId: some(UserId("u1")),
      communityId: none(CommunityId),
      role: roleMember,
      clientIp: "127.0.0.1",
      now: utcNow(),
    )
    check ctx.userId.isSome
    check ctx.communityId.isNone
    check ctx.role == roleMember
