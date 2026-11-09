import std/[options, random, unittest]
import ../domain/rating

proc params(): RatingParams =
  ## Mirrors the seeded defaults; tests own these numbers, production reads them.
  RatingParams(sessionBase: 250, scoreTarget: 21, opponentClampLow: 0.5, opponentClampHigh: 1.5,
    windowWeeks: 12, bestN: 10, thinEvidenceN: 3, topBandWidth: 100,
    bands: @[
      TierBand(tier: "D", floor: 1000, ceiling: some(1199.0)),
      TierBand(tier: "D+", floor: 1200, ceiling: some(1299.0)),
      TierBand(tier: "C", floor: 1300, ceiling: some(1499.0)),
      TierBand(tier: "C+", floor: 1500, ceiling: some(1599.0)),
      TierBand(tier: "B", floor: 1600, ceiling: some(1799.0)),
      TierBand(tier: "B+", floor: 1800, ceiling: some(1899.0)),
      TierBand(tier: "A", floor: 1900, ceiling: some(2099.0)),
      TierBand(tier: "A+", floor: 2100, ceiling: none(float))])

suite "rating domain":
  test "a game is worth between zero and twice half the base":
    check gameValue(250, 0, 21) == 125.0
    check gameValue(250, 21, 21) == 250.0
    check gameValue(250, -21, 21) == 0.0
    check gameValue(250, 21, 0) == 0.0

  test "a margin beyond the target cannot earn more than a clean win":
    check gameValue(250, 42, 21) == gameValue(250, 21, 21)
    check gameValue(250, -42, 21) == gameValue(250, -21, 21)

  test "points rise with the margin and stay inside the range":
    for target in [15.0, 21.0, 30.0]:
      var previous = -1.0
      for margin in -40 .. 40:
        let points = gameValue(250, margin.float, target)
        check points >= 0.0
        check points <= 250.0
        check points >= previous
        previous = points

  test "the opponent multiplier is neutral without data and clamped otherwise":
    let p = params()
    check opponentMultiplier(p, 0, 1500) == 1.0
    check opponentMultiplier(p, 1500, 0) == 1.0
    check opponentMultiplier(p, 1500, 1500) == 1.0
    check opponentMultiplier(p, 300, 1500) == 0.5
    check opponentMultiplier(p, 6000, 1500) == 1.5
    for opponent in [1.0, 500.0, 1500.0, 2400.0, 9000.0]:
      let value = opponentMultiplier(p, opponent, 1500)
      check value >= p.opponentClampLow
      check value <= p.opponentClampHigh

  test "tier strength is the band midpoint and the top band stays open":
    let p = params()
    check tierStrength(p, "D").get == 1099.5
    check tierStrength(p, "C").get == 1399.5
    check tierStrength(p, "A").get == 1999.5
    check tierStrength(p, "A+").get == 2200.0
    check tierStrength(p, "d").get == 1099.5
    check tierStrength(p, "").isNone
    check tierStrength(p, "Z").isNone

  test "the average skips unknown tiers instead of dragging it down":
    let p = params()
    check averageTierStrength(p, @["C", "Z", ""]) == 1399.5
    check averageTierStrength(p, @["", "Z"]) == 0.0

  test "points are rounded once and the multiplier applies to the total":
    let p = params()
    check roundPoints(124.4) == 124
    check roundPoints(124.5) == 125
    check entryPoints(p, @[250.0, 250.0], 1500, 1500) == 500
    check entryPoints(p, @[250.0, 250.0], 6000, 1500) == 750

  test "random margins keep every invariant":
    randomize(20261104)
    let p = params()
    for _ in 0 ..< 2000:
      let target = rand(5 .. 42).float
      let margin = rand(-99 .. 99).float
      let points = gameValue(p.sessionBase, margin, target)
      check points >= 0.0
      check points <= p.sessionBase
      if margin > 0:
        check points >= gameValue(p.sessionBase, 0, target)
      if margin < 0:
        check points <= gameValue(p.sessionBase, 0, target)
      let total = entryPoints(p, @[points], rand(0 .. 3000).float, 1500)
      check total >= 0
