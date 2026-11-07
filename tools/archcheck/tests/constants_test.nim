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

const boundsRegistry = """
  proc spec(key: ConfigKey, kind: ConfigType, minValue = 0.0,
            maxValue = 0.0, hasBounds = false,
            scope = csPlatform): KeySpec =
    KeySpec(key: key, kind: kind, minValue: minValue,
      maxValue: maxValue, hasBounds: hasBounds)

  allKeys* = [
    spec(keyRankBoardLimit, ctInt, 1, 10_000, true),
    spec(keySessionSlotMinutesDefault, ctInt, 1, 240, true),
    spec(keyRatingOpponentClamp, ctJson),
  ]
"""

const boundsKeys = """
    keyRankBoardLimit = "rank.board_limit"
    keySessionSlotMinutesDefault = "session.slot_minutes_default"
    keyRatingOpponentClamp = "rating.opponent_clamp"
"""

const boundsSeed = """
  ('rank.board_limit', 'int', '200', 1, 10000, 'platform',
   'Rows on the board'),
  ('session.slot_minutes_default', 'int', '30', 1, 240, 'platform',
   'Slot length'),
  ('rating.opponent_clamp', 'json', '{}', null, null, 'platform',
   'Clamp value'),
"""

suite "config bounds":
  test "registry specs are read with their database keys and bounds":
    let specs = registrySpecs(boundsKeys & boundsRegistry)
    check specs.len == 3
    check specs[0].key == "rank.board_limit"
    check specs[0].kind == "int"
    check specs[0].hasBounds
    check specs[0].minValue == 1.0
    check specs[0].maxValue == 10_000.0
    check not specs[2].hasBounds

  test "the seed keeps the bound columns":
    let rows = seedRows(boundsSeed)
    check rows.len == 3
    check rows[0].hasBounds
    check rows[0].minValue == 1.0
    check rows[0].maxValue == 10_000.0
    check not rows[2].hasBounds

  test "a registry max that the seed does not repeat is a violation":
    let drifted = (boundsKeys & boundsRegistry).replace("1, 240", "1, 241")
    let found = boundViolations(registrySpecs(drifted), seedRows(boundsSeed))
    check found.len == 1
    check found[0].contains("session.slot_minutes_default")
    check found[0].contains("max 241 does not match")

  test "matching bounds produce no violation":
    let specs = registrySpecs(boundsKeys & boundsRegistry)
    check boundViolations(specs, seedRows(boundsSeed)).len == 0

  test "a bound in the seed that the registry does not declare is a violation":
    let rows = seedRows(boundsSeed)
    var adjusted: seq[SeedRow] = @[]
    for row in rows:
      if row.key == "rating.opponent_clamp":
        adjusted.add(SeedRow(key: row.key, kind: row.kind, hasBounds: true,
          minValue: 1.0, maxValue: 2.0))
      else:
        adjusted.add(row)
    let found = boundViolations(registrySpecs(boundsKeys & boundsRegistry),
      adjusted)
    check found.len == 1
    check found[0].contains("rating.opponent_clamp declares no bounds")

  test "a registry key with no seed row is a violation":
    let rows = seedRows(boundsSeed)
    var kept: seq[SeedRow] = @[]
    for row in rows:
      if row.key != "session.slot_minutes_default":
        kept.add(row)
    let found = boundViolations(registrySpecs(boundsKeys & boundsRegistry),
      kept)
    check found.len == 1
    check found[0].contains("session.slot_minutes_default has no row in")

  test "a seed row the registry does not declare is a violation":
    var extra = seedRows(boundsSeed)
    extra.add(SeedRow(key: "rating.unknown", kind: "int", value: 7,
      hasValue: true))
    let found = boundViolations(registrySpecs(boundsKeys & boundsRegistry),
      extra)
    check found.len == 1
    check found[0].contains("rating.unknown is not declared in")

  test "a half-null bound pair is a violation":
    var adjusted: seq[SeedRow] = @[]
    for row in seedRows(boundsSeed):
      if row.key == "rank.board_limit":
        adjusted.add(SeedRow(key: row.key, kind: row.kind, value: row.value,
          hasValue: row.hasValue, partialBounds: true))
      else:
        adjusted.add(row)
    let found = boundViolations(registrySpecs(boundsKeys & boundsRegistry),
      adjusted)
    check found.len == 1
    check found[0].contains("only one of min_value/max_value")

suite "seed values":
  test "values come from the tuple parser, not the line scanner":
    let squashed = """('a.big', 'int', '120', null, null, 'platform', 'x'),
      ('a.small', 'int', '130', null, null, 'platform', 'y')"""
    let values = seededValues(squashed)
    check values.len == 2
