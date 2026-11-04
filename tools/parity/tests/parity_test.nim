import std/[json, strutils, unittest]
import ../normalizer
import ../state as parityState

suite "normalizer":
  test "replaces uuids, timestamps and share codes":
    let value =
      "id 11111111-2222-3333-4444-555555555555 at 2026-11-03T12:00:00Z in /s/abc123"
    check normalizeText(value) == "id {uuid} at {timestamp} in /s/{code}"

  test "sorts object keys and keeps arrays":
    let node = parseJson(
      """{"b":"2026-11-03T12:00:00Z","a":[1,"11111111-2222-3333-4444-555555555555"]}""")
    let normalized = normalizeJson(node)
    check $normalized == """{"a":[1,"{uuid}"],"b":"{timestamp}"}"""

  test "masks PostgreSQL text timestamps":
    check normalizeText("2026-11-04 14:06:13.353736+07") == "{timestamp}"

  test "masks websocket tickets and share codes":
    check normalizeText("ce9b722a88affbecd9508a7fdce9734732c3d0502dd3d554aca0abf9ff05478e") ==
      "{ticket}"
    check normalizeText("5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a") == "{shareCode}"

  test "masks oidc flow parameters but keeps the query":
    check normalizeText(
      "https://idp/authorize?state=deadbeef&nonce=cafe&code_challenge=xyz&client_id=1") ==
      "{authorizeUrl}?state={random}&nonce={random}&code_challenge={random}&client_id=1"

  test "masks the board as-of date only":
    let node = parseJson("""{"asOf":"2026-11-04","date":"2026-11-03"}""")
    check $normalizeJson(node) == """{"asOf":"{date}","date":"2026-11-03"}"""

suite "state projections":
  test "projection SQL pins the columns and the order":
    let projection = parityState.Projection(
      table: "platform.community",
      columns: @["slug", "name"],
      orderBy: @["slug"])
    let sql = parityState.projectionSql(projection)
    check sql.contains("select slug, name from platform.community order by slug")
    check sql.contains("jsonb_agg")

  test "projection SQL keeps an optional filter":
    let projection = parityState.Projection(
      table: "platform.community",
      columns: @["slug"],
      orderBy: @["slug"],
      whereClause: "slug = 'parity'")
    check parityState.projectionSql(projection).contains(
      "from platform.community where slug = 'parity' order by slug")

  test "a projection without ORDER BY is refused":
    let projection = parityState.Projection(
      table: "platform.community",
      columns: @["slug"])
    expect ValueError:
      discard parityState.projectionSql(projection)
