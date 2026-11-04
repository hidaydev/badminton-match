import std/[strutils, unittest]
import ../scan_constants

const seed = """
  ('rating.session_base', 'decimal', '250', 0, 100000, 'platform',
   'Base points for one session game'),
  ('rank.board_limit', 'int', '200', 0, 1000, 'platform',
   'Rows on the board'),
  ('security.max_json_depth', 'int', '16', 1, 64, 'platform',
   'Depth limit'),
  ('community.invite_ttl_days', 'int', '7', 1, 365, 'platform',
   'Invite lifetime'),
  ('audit.retention_days', 'int', '365', 1, 3650, 'platform',
   'Audit lifetime'),
"""

suite "business constants":
  test "only values above the floor and outside the protocol set are read":
    let values = seededValues(seed)
    var seen: seq[int] = @[]
    for entry in values:
      seen.add(entry.value)
    check 250 in seen
    check 365 in seen
    # Below the floor: too easy to confuse with a loop bound.
    check 16 notin seen
    check 7 notin seen
    # Also an HTTP status, so the scan cannot tell them apart.
    check 200 notin seen
    check values[0].key == "rating.session_base"

  test "a literal that repeats a seeded value is a violation":
    let values = seededValues(seed)
    let found = constantViolations("modules/rating/x.nim",
      "proc base(): int = 250\n", values)
    check found.len == 1
    check found[0].contains("modules/rating/x.nim:1")
    check found[0].contains("rating.session_base")

  test "strings, comments and longer numbers are not literals":
    let values = seededValues(seed)
    check constantViolations("modules/rating/x.nim",
      """let q = "250"  # 250
let n = 1250
let m = 2500
""", values).len == 0

  test "the allowlist exempts one literal or a whole file":
    let values = seededValues(seed)
    let source = "let a = 250\nlet b = 365\n"
    check constantViolations("modules/rating/x.nim", source, values,
      ["modules/rating/x.nim:250"]).len == 1
    check constantViolations("modules/rating/x.nim", source, values,
      ["modules/rating/x.nim"]).len == 0

  test "the allowlist parser ignores comments and blank lines":
    let entries = loadAllowlist("""
# a reason
modules/rating/x.nim:250   # inline reason

apps/api/src/main.nim
""")
    check entries == @["modules/rating/x.nim:250", "apps/api/src/main.nim"]
