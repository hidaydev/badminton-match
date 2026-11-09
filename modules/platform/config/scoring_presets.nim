## The scoring preset shape and the validation of a stored preset list.
##
## It lives with the platform config because `session.scoring_presets` is a
## platform key: the snapshot loader must refuse a malformed list, and it must
## not import a feature module to do so. `session/scoring` imports this module
## and adds the runtime rules: set validation, margins, serialisation.

import std/[json, options, strutils]

type
  ScoringMode* = enum
    smPreset = "preset"
    smLegacy = "legacy"

  ScoringRules* = object
    ## One session's frozen format. `mode` is the only behaviour switch:
    ## `legacy` keeps v1's "any non-tie in range" validation for old rows.
    id*: string
    label*: string
    mode*: ScoringMode
    gamesToWin*: int
    pointsToWin*: int
    winBy*: int
    deuceAt*: Option[int]
    maxPoints*: int
    changeEndsAt*: Option[int]

  SetConfigError* = object of CatchableError
    ## A malformed preset is a configuration error, not something to paper over
    ## with a default. The loader turns this into a refused start.

const
  legacyPresetId* = "legacy_v1"
  minSetsToWin* = 1
  maxSetsToWin* = 5
  scoreCeiling* = 99

  legacyRules* = ScoringRules(
    id: legacyPresetId,
    label: "v1 scoring",
    mode: smLegacy,
    gamesToWin: 1,
    pointsToWin: 30,
    winBy: 1,
    deuceAt: none(int),
    maxPoints: scoreCeiling,
    changeEndsAt: some(15))

proc fail(path: string): ref SetConfigError =
  newException(SetConfigError, path)

proc jsonInt(node: JsonNode, key, path: string): int =
  if not node.hasKey(key) or node[key].kind != JInt:
    raise fail(path & "." & key & " must be an integer")
  node[key].getInt()

proc jsonString(node: JsonNode, key, path: string): string =
  if not node.hasKey(key) or node[key].kind != JString:
    raise fail(path & "." & key & " must be a string")
  node[key].getStr()

proc optionalInt(node: JsonNode, key, path: string): Option[int] =
  if not node.hasKey(key) or node[key].kind == JNull:
    return none(int)
  if node[key].kind != JInt:
    raise fail(path & "." & key & " must be an integer or null")
  some(node[key].getInt())

proc validId(id: string): bool =
  ## Preset ids end up in a URL-less JSON field and in log lines, so keep them
  ## boring: lower case, digits, underscore.
  if id.len < 2 or id.len > 32:
    return false
  for c in id:
    if c notin {'a'..'z', '0'..'9', '_'}:
      return false
  true

proc parseRules(node: JsonNode, path: string, requireMode: bool): ScoringRules =
  if node.kind != JObject:
    raise fail(path & " must be an object")
  result.id = jsonString(node, "id", path)
  if not validId(result.id):
    raise fail(path & ".id must be 2..32 lower-case letters, digits or underscore")
  result.label = jsonString(node, "label", path).strip()
  if result.label.len == 0:
    raise fail(path & ".label must not be blank")

  if requireMode and node.hasKey("mode"):
    case node["mode"].kind
    of JString:
      case node["mode"].getStr()
      of "preset": result.mode = smPreset
      of "legacy": result.mode = smLegacy
      else: raise fail(path & ".mode must be preset or legacy")
    else:
      raise fail(path & ".mode must be a string")
  else:
    result.mode = smPreset

  result.gamesToWin = jsonInt(node, "gamesToWin", path)
  if result.gamesToWin < minSetsToWin or result.gamesToWin > maxSetsToWin:
    raise fail(path & ".gamesToWin must be " & $minSetsToWin & ".." &
      $maxSetsToWin)
  result.pointsToWin = jsonInt(node, "pointsToWin", path)
  if result.pointsToWin < 1 or result.pointsToWin > scoreCeiling:
    raise fail(path & ".pointsToWin must be 1.." & $scoreCeiling)
  result.winBy = jsonInt(node, "winBy", path)
  if result.winBy < 1 or result.winBy > 10:
    raise fail(path & ".winBy must be 1..10")
  result.maxPoints = jsonInt(node, "maxPoints", path)
  if result.maxPoints < result.pointsToWin or result.maxPoints > scoreCeiling:
    raise fail(path & ".maxPoints must be at least pointsToWin and at most " &
      $scoreCeiling)

  result.deuceAt = optionalInt(node, "deuceAt", path)
  if result.deuceAt.isSome:
    let deuce = result.deuceAt.get
    if deuce < result.pointsToWin - 1 or deuce >= result.maxPoints:
      raise fail(path & ".deuceAt must be " & $(result.pointsToWin - 1) & ".." &
        $(result.maxPoints - 1))

  result.changeEndsAt = optionalInt(node, "changeEndsAt", path)
  if result.changeEndsAt.isSome:
    let change = result.changeEndsAt.get
    if change < 1 or change >= result.pointsToWin:
      raise fail(path & ".changeEndsAt must be 1.." & $(result.pointsToWin - 1))

proc parseSnapshotNode*(node: JsonNode): ScoringRules =
  ## A snapshot is written by the server, so `mode` is honoured; an older row
  ## without it is a preset.
  parseRules(node, "scoring_rules", requireMode = true)

proc parsePresetNode*(node: JsonNode, path: string): ScoringRules =
  parseRules(node, path, requireMode = false)

proc parsePresets*(node: JsonNode): seq[ScoringRules] =
  ## The platform list. Empty, duplicated or reserved ids are refused: the
  ## wizard must always have at least one pickable format.
  if node.kind != JArray or node.len == 0 or node.len > 20:
    raise fail("session.scoring_presets must be a non-empty array (max 20)")
  var seen: seq[string] = @[]
  for index in 0 ..< node.len:
    let entry = node[index]
    let path = "session.scoring_presets[" & $index & "]"
    let rules = parsePresetNode(entry, path)
    if rules.id == legacyPresetId:
      raise fail(path & ".id is reserved")
    if rules.id in seen:
      raise fail("duplicate preset id: " & rules.id)
    seen.add(rules.id)
    result.add(rules)

proc rulesJson*(rules: ScoringRules): JsonNode =
  result = %*{
    "id": rules.id,
    "label": rules.label,
    "mode": $rules.mode,
    "gamesToWin": rules.gamesToWin,
    "pointsToWin": rules.pointsToWin,
    "winBy": rules.winBy,
    "maxPoints": rules.maxPoints,
  }
  result["deuceAt"] =
    if rules.deuceAt.isSome: %rules.deuceAt.get else: newJNull()
  result["changeEndsAt"] =
    if rules.changeEndsAt.isSome: %rules.changeEndsAt.get else: newJNull()

