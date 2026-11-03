import std/[json, unittest]
import ../normalizer

suite "normalizer":
  test "replaces uuids, timestamps and share codes":
    let value = "id 11111111-2222-3333-4444-555555555555 at 2026-11-03T12:00:00Z in /s/abc123"
    check normalizeText(value) == "id {uuid} at {timestamp} in /s/{code}"

  test "sorts object keys and keeps arrays":
    let node = parseJson("""{"b":"2026-11-03T12:00:00Z","a":[1,"11111111-2222-3333-4444-555555555555"]}""")
    let normalized = normalizeJson(node)
    check $normalized == """{"a":[1,"{uuid}"],"b":"{timestamp}"}"""
