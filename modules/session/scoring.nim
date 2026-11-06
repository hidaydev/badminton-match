## Match scoring rules: a match is one slot, and a match is 1..N sets.
##
## This module is pure: no database, no config snapshot, no clock. The API, the
## rating projection, and the web client all describe the same rules, and the
## unit tests below are the table both sides must agree on.

import std/[json, options, strutils]

type
  Side* = enum
    sdA = "a"
    sdB = "b"

  SetScore* = object
    a*: int
    b*: int

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

  SetError* = enum
    seOk = "ok"
    seTie = "tie"
    seRange = "range"
    seTooFewPoints = "too_few_points"
    seAboveCap = "above_cap"
    seWinBy = "win_by"
    seTooManySets = "too_many_sets"
    seSetAfterEnd = "set_after_end"
    seNotContiguous = "not_contiguous"

  SetVerdict* = object
    ## `setIndex` is 1-based; zero means the complaint is about the list.
    error*: SetError
    setIndex*: int

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

proc validSet*(rules: ScoringRules, s: SetScore): SetError =
  ## One completed set. The cap is checked before `winBy`: 30-29 in a 21-point
  ## game is decided by the cap, not sent back to deuce.
  if s.a < 0 or s.b < 0 or s.a > scoreCeiling or s.b > scoreCeiling:
    return seRange
  if s.a == s.b:
    return seTie
  if rules.mode == smLegacy:
    ## v1 had no format rule: any non-tie in range was a valid game.
    return seOk
  let high = max(s.a, s.b)
  let low = min(s.a, s.b)
  if high > rules.maxPoints:
    return seAboveCap
  if high < rules.pointsToWin:
    return seTooFewPoints
  if high == rules.maxPoints:
    return seOk
  let need = if rules.deuceAt.isSome and low >= rules.deuceAt.get:
               rules.winBy
             else:
               1
  if high - low < need: seWinBy else: seOk

proc validateSets*(rules: ScoringRules,
                   sets: openArray[SetScore]): SetVerdict =
  ## The whole list, in order. A match stops the moment one side reaches
  ## `gamesToWin`; a further set is refused instead of silently ignored.
  if sets.len > 2 * rules.gamesToWin - 1:
    return SetVerdict(error: seTooManySets)
  var wonA, wonB = 0
  for index, s in sets:
    let single = validSet(rules, s)
    if single != seOk:
      return SetVerdict(error: single, setIndex: index + 1)
    if wonA >= rules.gamesToWin or wonB >= rules.gamesToWin:
      return SetVerdict(error: seSetAfterEnd, setIndex: index + 1)
    if s.a > s.b: inc wonA else: inc wonB
  SetVerdict(error: seOk)

proc setsWon*(sets: openArray[SetScore]): (int, int) =
  for s in sets:
    if s.a > s.b: inc result[0] else: inc result[1]

proc matchComplete*(rules: ScoringRules, sets: openArray[SetScore]): bool =
  let (a, b) = setsWon(sets)
  a >= rules.gamesToWin or b >= rules.gamesToWin

proc winnerSide*(rules: ScoringRules, sets: openArray[SetScore]): Option[Side] =
  let (a, b) = setsWon(sets)
  if a >= rules.gamesToWin: some(sdA)
  elif b >= rules.gamesToWin: some(sdB)
  else: none(Side)

proc points*(sets: openArray[SetScore]): (int, int) =
  ## Total points across every stored set, not points per won set.
  for s in sets:
    result[0] += s.a
    result[1] += s.b

proc parseSets*(node: JsonNode): seq[SetScore] =
  ## Request body: `{"sets": [{"a": 21, "b": 18}, ...]}`. The engine validates
  ## the rules; this only checks the shape, so a malformed body is a 400 and
  ## never a crash.
  if node.kind != JArray:
    raise newException(ValueError, "sets must be an array")
  for index in 0 ..< node.len:
    let item = node[index]
    if item.kind != JObject:
      raise newException(ValueError, "set " & $(index + 1) & " must be an object")
    if not item.hasKey("a") or item["a"].kind != JInt or
       not item.hasKey("b") or item["b"].kind != JInt:
      raise newException(ValueError,
        "set " & $(index + 1) & ": a and b must be integers")
    result.add SetScore(a: item["a"].getInt(), b: item["b"].getInt())

proc ratingMargin*(rules: ScoringRules, sets: openArray[SetScore]): float =
  ## Average margin per set, relative to the format's target:
  ##
  ##   r = sum(a - b) / (pointsToWin * setsPlayed)
  ##
  ## The caller feeds `r * pointsToWin` into gameValue(base, margin, target)
  ## with target = pointsToWin, so a single set reduces to the v1 formula.
  if sets.len == 0 or rules.pointsToWin <= 0:
    return 0.0
  var total = 0
  for s in sets:
    total += s.a - s.b
  total.float / (rules.pointsToWin.float * sets.len.float)

proc ratingMarginFrom*(pointsA, pointsB, setsPlayed, target: int): float =
  ## The ratio from the results view, without loading every set:
  ## `pointsA - pointsB` is `sum(a - b)` by construction.
  if setsPlayed <= 0 or target <= 0:
    return 0.0
  (pointsA - pointsB).float / (target.float * setsPlayed.float)

proc ratingMargin*(rules: ScoringRules, pointsA, pointsB,
                   setsPlayed: int): float =
  ratingMarginFrom(pointsA, pointsB, setsPlayed, rules.pointsToWin)