## The table the engine, the API and the web client all have to agree on.

import std/[json, options, unittest]
import ../scoring

proc set(a, b: int): SetScore = SetScore(a: a, b: b)

let majadu = ScoringRules(id: "majadu30", label: "MAJADU 30", mode: smPreset,
  gamesToWin: 1, pointsToWin: 30, winBy: 1, deuceAt: none(int),
  maxPoints: 30, changeEndsAt: some(15))
let classic = ScoringRules(id: "classic21", label: "Classic BO3 21",
  mode: smPreset, gamesToWin: 2, pointsToWin: 21, winBy: 2, deuceAt: some(20),
  maxPoints: 30, changeEndsAt: some(11))
let bwf = ScoringRules(id: "bwf15", label: "New BWF BO3 15", mode: smPreset,
  gamesToWin: 2, pointsToWin: 15, winBy: 2, deuceAt: some(14),
  maxPoints: 21, changeEndsAt: some(8))

suite "single set validation":
  test "MAJADU 30":
    check validSet(majadu, set(30, 29)) == seOk
    check validSet(majadu, set(29, 28)) == seTooFewPoints
    check validSet(majadu, set(30, 0)) == seOk
    check validSet(majadu, set(0, 30)) == seOk
    check validSet(majadu, set(31, 29)) == seAboveCap
    check validSet(majadu, set(15, 15)) == seTie

  test "Classic 21":
    check validSet(classic, set(21, 19)) == seOk
    check validSet(classic, set(21, 20)) == seWinBy
    check validSet(classic, set(22, 20)) == seOk
    check validSet(classic, set(20, 18)) == seTooFewPoints
    check validSet(classic, set(30, 29)) == seOk
    check validSet(classic, set(29, 28)) == seWinBy
    check validSet(classic, set(31, 29)) == seAboveCap

  test "New BWF 15":
    check validSet(bwf, set(15, 13)) == seOk
    check validSet(bwf, set(15, 14)) == seWinBy
    check validSet(bwf, set(16, 14)) == seOk
    check validSet(bwf, set(14, 12)) == seTooFewPoints
    check validSet(bwf, set(21, 20)) == seOk
    check validSet(bwf, set(20, 19)) == seWinBy
    check validSet(bwf, set(22, 20)) == seAboveCap

  test "legacy keeps v1's loose rule":
    check validSet(legacyRules, set(21, 19)) == seOk
    check validSet(legacyRules, set(30, 5)) == seOk
    check validSet(legacyRules, set(0, 5)) == seOk
    check validSet(legacyRules, set(5, 5)) == seTie
    check validSet(legacyRules, set(100, 5)) == seRange

suite "set list":
  test "counts sets, not points":
    let sets = @[set(21, 19), set(19, 21), set(21, 17)]
    check setsWon(sets) == (2, 1)
    check matchComplete(classic, sets)
    check winnerSide(classic, sets) == some(sdA)
    check points(sets) == (61, 57)

  test "partial match is not complete":
    let sets = @[set(21, 19), set(19, 21)]
    check setsWon(sets) == (1, 1)
    check not matchComplete(classic, sets)
    check winnerSide(classic, sets).isNone

  test "a single-set format is complete after one set":
    check matchComplete(majadu, @[set(30, 28)])
    check winnerSide(majadu, @[set(28, 30)]) == some(sdB)

  test "no set after the match is decided":
    check validateSets(classic,
      @[set(21, 19), set(21, 19), set(21, 19)]).error == seSetAfterEnd
    check validateSets(classic,
      @[set(21, 19), set(21, 19), set(21, 19)]).setIndex == 3

  test "too many sets":
    check validateSets(majadu, @[set(30, 28), set(30, 28)]).error ==
      seTooManySets

  test "invalid set names its position":
    let verdict = validateSets(classic, @[set(21, 19), set(21, 20)])
    check verdict.error == seWinBy
    check verdict.setIndex == 2

  test "empty list is allowed (clearing a score)":
    check validateSets(classic, @[]).error == seOk

suite "rating margin":
  test "single set is the v1 formula":
    check abs(ratingMargin(majadu, @[set(30, 28)]) - (2.0 / 30.0)) < 0.000001
    check abs(ratingMargin(legacyRules, @[set(30, 28)]) - (2.0 / 30.0)) <
      0.000001

  test "BO3 averages per set played":
    # 21-19, 21-19: +4 over two sets of 21.
    check abs(ratingMargin(classic, @[set(21, 19), set(21, 19)]) -
      (4.0 / 42.0)) < 0.000001
    # 21-19, 19-21, 21-19: +2 over three sets.
    check abs(ratingMargin(classic,
      @[set(21, 19), set(19, 21), set(21, 19)]) - (2.0 / 63.0)) < 0.000001

  test "the view's totals give the same ratio":
    check abs(ratingMargin(classic, 61, 57, 3) -
      ratingMargin(classic, @[set(21, 19), set(19, 21), set(21, 17)])) <
      0.000001

  test "no sets means no margin":
    check ratingMargin(classic, @[]) == 0.0
    check ratingMargin(classic, 0, 0, 0) == 0.0

suite "configuration":
  let presets = parseJson("""
    [
      {"id":"majadu30","label":"MAJADU 30","gamesToWin":1,"pointsToWin":30,
       "winBy":1,"deuceAt":null,"maxPoints":30,"changeEndsAt":15},
      {"id":"classic21","label":"Classic BO3 21","gamesToWin":2,
       "pointsToWin":21,"winBy":2,"deuceAt":20,"maxPoints":30,"changeEndsAt":11}
    ]""")

  test "parses and round-trips":
    let rules = parsePresets(presets)
    check rules.len == 2
    check rules[0].id == "majadu30"
    check rules[1].deuceAt == some(20)
    check parseSnapshotNode(rulesJson(rules[1])) == rules[1]

  test "rejects a reserved id":
    var bad = parseJson("""[
      {"id":"legacy_v1","label":"x","gamesToWin":1,"pointsToWin":30,
       "winBy":1,"deuceAt":null,"maxPoints":30,"changeEndsAt":15}]""")
    expect SetConfigError:
      discard parsePresets(bad)

  test "rejects duplicates":
    var bad = parseJson("""[
      {"id":"a1","label":"x","gamesToWin":1,"pointsToWin":30,
       "winBy":1,"deuceAt":null,"maxPoints":30,"changeEndsAt":15},
      {"id":"a1","label":"y","gamesToWin":1,"pointsToWin":30,
       "winBy":1,"deuceAt":null,"maxPoints":30,"changeEndsAt":15}]""")
    expect SetConfigError:
      discard parsePresets(bad)

  test "rejects a cap below the target":
    var bad = parseJson("""[
      {"id":"a1","label":"x","gamesToWin":1,"pointsToWin":21,
       "winBy":1,"deuceAt":null,"maxPoints":20,"changeEndsAt":15}]""")
    expect SetConfigError:
      discard parsePresets(bad)

  test "rejects deuce outside the range":
    var bad = parseJson("""[
      {"id":"a1","label":"x","gamesToWin":2,"pointsToWin":21,
       "winBy":2,"deuceAt":30,"maxPoints":30,"changeEndsAt":11}]""")
    expect SetConfigError:
      discard parsePresets(bad)

  test "rejects a blank label":
    var bad = parseJson("""[
      {"id":"a1","label":" ","gamesToWin":1,"pointsToWin":30,
       "winBy":1,"deuceAt":null,"maxPoints":30,"changeEndsAt":15}]""")
    expect SetConfigError:
      discard parsePresets(bad)

  test "snapshot keeps legacy mode":
    let legacy = parseSnapshotNode(rulesJson(legacyRules))
    check legacy.mode == smLegacy
    check legacy.pointsToWin == 30
    check legacy.maxPoints == scoreCeiling