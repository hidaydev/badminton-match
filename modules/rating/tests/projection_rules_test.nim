## The placement and ratio rules the board applies to a tournament entry. They
## are pure functions inside `projection.nim`, and until this suite existed the
## only way to reach them was a database read of a finished tournament, so a
## wrong fallback ratio could survive every suite in the tree.

import std/[json, unittest]
import ../projection

proc level(ratios: string): Level =
  Level(champion: 1000.0, ratios: parseJson(ratios), enabled: true)

proc placement(bestRank: int, anyWin: bool, finalOutcome: string): Place =
  Place(bestRank: bestRank, anyWin: anyWin, finalOutcome: finalOutcome)

suite "resultKey":
  test "a final win is the champion and a final loss is the runner up":
    check resultKey(placement(4, true, "W")) == "final"
    check resultKey(placement(4, true, "L")) == "runner_up"

  test "a player who won nothing is a participant wherever they stopped":
    for rank in 0 .. 4:
      check resultKey(placement(rank, false, "")) == "participant"

  test "the earlier rounds map to the phase the player reached":
    check resultKey(placement(3, true, "")) == "sf"
    check resultKey(placement(2, true, "")) == "qf"
    check resultKey(placement(1, true, "")) == "group"
    check resultKey(placement(0, true, "")) == "participant"

suite "phaseRank":
  test "the third place match counts as a semifinal":
    check phaseRank("3rd") == phaseRank("sf")
    check phaseRank("3rd") == 3

  test "the rounds are ordered group, qf, sf, final":
    check phaseRank("group") < phaseRank("qf")
    check phaseRank("qf") < phaseRank("sf")
    check phaseRank("sf") < phaseRank("final")

  test "an unknown phase ranks below the group stage":
    check phaseRank("") == 0
    check phaseRank("round_of_64") == 0

suite "ratioOf":
  test "a ladder row wins over the fallback":
    let custom = level("""{"sf": 0.9, "final": 0.95}""")
    check ratioOf(custom, "sf") == 0.9
    check ratioOf(custom, "final") == 0.95

  test "a missing key falls back to the v1 default table":
    let empty = level("{}")
    check ratioOf(empty, "final") == 1.0
    check ratioOf(empty, "runner_up") == 0.85
    check ratioOf(empty, "sf") == 0.7
    check ratioOf(empty, "qf") == 0.55
    check ratioOf(empty, "group") == 0.4
    check ratioOf(empty, "participant") == 0.2

  test "an unknown key is worth nothing":
    check ratioOf(level("{}"), "quarterfinal") == 0.0
    check defaultRatio("quarterfinal") == 0.0

  test "a ladder that is not an object falls back instead of failing":
    let broken = Level(champion: 1000.0, ratios: newJNull(), enabled: true)
    check ratioOf(broken, "sf") == 0.7

suite "splitKey":
  test "a key with the separator round-trips":
    let key = "player-1" & "\x00" & "source-1"
    let (owner, source) = splitKey(key)
    check owner == "player-1"
    check source == "source-1"
    check splitKey(owner & "\x00" & source) == (owner, source)

  test "a key without the separator has no source":
    check splitKey("player-1") == ("player-1", "")

suite "tournament placement":
  test "a ladder row changes the payout of every placement it names":
    let ladder = level("""{"final": 1.0, "runner_up": 0.5, "sf": 0.25}""")
    check ladder.champion * ratioOf(ladder, "runner_up") == 500.0
    check ladder.champion * ratioOf(ladder, "sf") == 250.0
    check ladder.champion * ratioOf(ladder, "qf") == 550.0