import std/[json, options, os, times, unittest]
import ../clock
import ../context
import ../errors
import ../logger
import ../metrics
import ../sha256
import ../uuidv7

suite "sha256":
  test "matches the standard vector":
    check sha256Hex("abc") ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

suite "clock":
  test "MAJADU_NOW forces the clock":
    putEnv("MAJADU_NOW", "2026-11-03T12:00:00Z")
    check utcNow() == parse("2026-11-03T12:00:00Z", "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
    delEnv("MAJADU_NOW")

  test "invalid MAJADU_NOW refuses to start":
    putEnv("MAJADU_NOW", "2026-11-03 12:00:00")
    expect ValueError:
      discard utcNow()
    delEnv("MAJADU_NOW")

suite "uuidv7":
  test "sets the version and variant bits":
    let bytes = uuidv7Bytes(1_700_000_000_000)
    check (bytes[6] shr 4) == 7
    check (bytes[8] shr 6) == 2

  test "orders by timestamp":
    check uuidv7(1_700_000_000_000) < uuidv7(1_700_000_001_000)

suite "redaction":
  test "share code path":
    check redact("/s/abc123") == "/s/{code}"

  test "ws ticket query":
    check redact("?ticket=secret") == "?ticket=REDACTED"

  test "auth and cookie headers":
    check redact("Authorization: Bearer xyz") == "Authorization: REDACTED"
    check redact("Cookie: sid=abc") == "Cookie: REDACTED"

  test "email and ip":
    check redact("user@example.com") == "{email}"
    check redact("127.0.0.1") == "{ip}"

  test "log line is one json object":
    let line = renderLog("info", "request", [("path", "/s/abc123"), ("ip", "10.0.0.1")])
    let node = parseJson(line)
    check node["msg"].getStr() == "request"
    check node["path"].getStr() == "/s/{code}"
    check node["ip"].getStr() == "{ip}"

suite "metrics":
  test "template route collapses identifiers":
    check templateRoute("/s/abc123") == "/s/{code}"
    check templateRoute("/s/abc123/rankings") == "/s/{code}/rankings"
    check templateRoute("/c/my-club/rankings") == "/c/{slug}/rankings"
    check templateRoute("/c/my-club/sessions/42") == "/c/{slug}/sessions/{id}"

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
