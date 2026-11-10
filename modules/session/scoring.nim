## Match scoring rules: a match is one slot, and a match is 1..N sets.
##
## This module is pure: no database, no config snapshot, no clock. The API, the
## rating projection, and the web client all describe the same rules, and the
## unit tests below are the table both sides must agree on.

import std/[json, options]
import platform/config/scoring_presets

# The preset shape lives with the platform config, which validates the stored
# list at load time; this module keeps the runtime rules on top of it. Callers
# still name the shape through `sessionScoring`.
export scoring_presets

type
  Side* = enum
    sdA = "a"
    sdB = "b"

  SetScore* = object
    a*: int
    b*: int

  SetError* = enum
    seOk = "ok"
    seTie = "tie"
    seRange = "range"
    seTooFewPoints = "too_few_points"
    seAboveCap = "above_cap"
    seWinBy = "win_by"
    seTooManySets = "too_many_sets"
    seSetAfterEnd = "set_after_end"
    seSetsRequired = "sets_required"

  SetVerdict* = object
    ## `setIndex` is 1-based; zero means the complaint is about the list.
    error*: SetError
    setIndex*: int


proc flatScoreAllowed*(rules: ScoringRules): bool =
  ## A bare `scoreA`/`scoreB` body is a single set, so it only fits a
  ## single-set format; a best-of-N session must send the `sets` list.
  rules.gamesToWin == 1

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
  ## A tied set counts for neither side. `validateSets` already refuses a tie,
  ## but `matchComplete` and `winnerSide` are exported and take sets from any
  ## caller: awarding a tie to side B would make a single-set draw look like a
  ## played game with the wrong winner (SQ-22).
  for s in sets:
    if s.a > s.b: inc result[0]
    elif s.b > s.a: inc result[1]

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