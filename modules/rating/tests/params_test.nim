## `loadRatingParams` is the only place the point formula reads its numbers.
## Every other rating suite hand-builds `RatingParams`, which is why a wrong key
## or a dropped band could ship without a case. The values below are the seeded
## rows in `db/seeds/platform_config.sql`, not a second copy of the defaults:
## production reads them from the registry, so the test reads them from the same
## shape the registry load produces.

import std/[json, options, strutils, tables, unittest]
import ../domain/rating
import ../infrastructure/params
import platform/config/store

const seededBands = """[
  {"tier":"D","min":1000,"max":1199},
  {"tier":"D+","min":1200,"max":1299},
  {"tier":"C","min":1300,"max":1499},
  {"tier":"C+","min":1500,"max":1599},
  {"tier":"B","min":1600,"max":1799},
  {"tier":"B+","min":1800,"max":1899},
  {"tier":"A","min":1900,"max":2099},
  {"tier":"A+","min":2100,"max":null}]"""

const expectedBands = [
  ("D", 1000.0, 1199.0),
  ("D+", 1200.0, 1299.0),
  ("C", 1300.0, 1499.0),
  ("C+", 1500.0, 1599.0),
  ("B", 1600.0, 1799.0),
  ("B+", 1800.0, 1899.0),
  ("A", 1900.0, 2099.0),
]

proc registryValues(): Table[string, JsonNode] =
  ## Every key `loadRatingParams` reads, filled with the seeded value. A key
  ## this builder forgets surfaces as a missing-key error, which is exactly the
  ## failure the case for a missing key asserts.
  result = initTable[string, JsonNode]()
  result[$keyRatingSessionBase] = %250
  result[$keyRatingScoreTarget] = %30
  result[$keyRatingWindowWeeks] = %12
  result[$keyRatingBestN] = %10
  result[$keyRatingThinEvidenceN] = %3
  result[$keyRatingTopBandWidth] = %100
  result[$keyRatingOpponentClamp] = parseJson("[0.5,1.5]")
  result[$keyRatingTierBands] = parseJson(seededBands)

proc snapshot(values: Table[string, JsonNode]): Snapshot =
  Snapshot(version: 1, values: values)

proc seeded(): Snapshot = snapshot(registryValues())

proc messageOf(work: proc()): string =
  ## The message is part of the contract: an operator reading a refused start
  ## must see which key is wrong, not only that something was.
  try:
    work()
  except ConfigError as error:
    return error.msg

suite "rating params from the registry":
  test "the seeded registry produces the seeded numbers and bands":
    let params = loadRatingParams(seeded(), %*{})
    check params.sessionBase == 250.0
    check params.scoreTarget == 30
    check params.windowWeeks == 12
    check params.bestN == 10
    check params.thinEvidenceN == 3
    check params.topBandWidth == 100
    check params.opponentClampLow == 0.5
    check params.opponentClampHigh == 1.5
    check params.bands.len == expectedBands.len + 1
    for index, (tier, floor, ceiling) in expectedBands:
      check params.bands[index].tier == tier
      check params.bands[index].floor == floor
      check params.bands[index].ceiling == some(ceiling)

  test "the top band stays open ended":
    let params = loadRatingParams(seeded(), %*{})
    let top = params.bands[^1]
    check top.tier == "A+"
    check top.floor == 2100.0
    check top.ceiling.isNone
    check tierStrength(params, "A+") == some(2200.0)

  test "the top band width arrives from the registry":
    ## SQ-20: the width above the open band used to be a literal, so an
    ## operator could not move a top-band player's rating without a rebuild.
    let narrow = loadRatingParams(seeded(), %*{"rating.top_band_width": 40})
    check tierStrength(narrow, "A+") == some(2140.0)
    var values = registryValues()
    values[$keyRatingTopBandWidth] = %250
    let wide = loadRatingParams(snapshot(values), %*{})
    check tierStrength(wide, "A+") == some(2350.0)

  test "a missing key names the key it could not read":
    var values = registryValues()
    values.del($keyRatingWindowWeeks)
    let message = messageOf(proc() =
      discard loadRatingParams(snapshot(values), %*{}))
    check message.contains($keyRatingWindowWeeks)

  test "a malformed clamp is a configuration error that names the key":
    for clamp in ["[0.5]", "[0,1.5]", "[-1,1.5]", "[1.5,0.5]", "0.5"]:
      var values = registryValues()
      values[$keyRatingOpponentClamp] = parseJson(clamp)
      let message = messageOf(proc() =
        discard loadRatingParams(snapshot(values), %*{}))
      check message.contains($keyRatingOpponentClamp)

  test "a band needs a tier and a floor, and its ceiling must be above it":
    for bands in [
      """[{"min":1000,"max":1199}]""",
      """[{"tier":"D","max":1199}]""",
      """[{"tier":"D","min":1200,"max":1199}]""",
      """[{"tier":"D","min":1200,"max":1200}]""",
    ]:
      var values = registryValues()
      values[$keyRatingTierBands] = parseJson(bands)
      let message = messageOf(proc() =
        discard loadRatingParams(snapshot(values), %*{}))
      check message.contains($keyRatingTierBands)

  test "an override narrows the platform value and never widens it":
    let params = loadRatingParams(seeded(),
      %*{"rating.best_n": 4, "rating.session_base": 900})
    check params.bestN == 4
    check params.sessionBase == 250.0