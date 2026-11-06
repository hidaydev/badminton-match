import std/[algorithm, options, unittest]
import ../domain/classic
import ../domain/classic_draw

proc makePairs(): seq[Pair] =
  for index in 1 .. PairCount:
    let first = (index - 1) * 2 + 1
    let second = first + 1
    result.add Pair(id: "p" & $index,
      name: "Player " & $first & " & Player " & $second)

proc generated(seed: int64): ClassicTournament =
  generateTournament("Anniversary Cup", "2026-11-04", makePairs(), seed)

proc kinds(issues: seq[ClassicIssue]): seq[ClassicIssueKind] =
  for issue in issues:
    result.add(issue.kind)

proc byId(tournament: ClassicTournament, id: string): ClassicMatch =
  for match in tournament.matches:
    if match.id == id:
      return match
  raise newException(ValueError, "match not found: " & id)

proc setScore(tournament: var ClassicTournament, id: string, a, b: int) =
  for match in tournament.matches.mitems:
    if match.id == id:
      match.scoreA = some(a)
      match.scoreB = some(b)

proc scored(scores: openArray[(string, int, int)]): ClassicTournament =
  result = generated(7)
  for entry in scores:
    result.setScore(entry[0], entry[1], entry[2])

proc withPropagation(tournament: ClassicTournament): ClassicTournament =
  result = tournament
  result.matches = propagateBracket(result.matches, result.groups)

proc groupMatch(id, pairA, pairB: string, scoreA, scoreB: int): ClassicMatch =
  ClassicMatch(id: id, phase: cpGroup, groupId: some(ga),
    pairAId: some(pairA), pairBId: some(pairB),
    scoreA: some(scoreA), scoreB: some(scoreB))

suite "classic generation":
  test "a drawn tournament validates clean":
    let tournament = generated(7)
    check validate(tournament).len == 0
    check tournament.pairs.len == PairCount
    check tournament.matches.len == MatchCount
    var phases: array[ClassicPhase, int]
    for match in tournament.matches:
      phases[match.phase].inc
    check phases[cpGroup] == GroupMatchCount
    check phases[cpQf] == 4
    check phases[cpSf] == 2
    check phases[cpThird] == 1
    check phases[cpFinal] == 1

  test "the same seed draws the same tournament":
    let first = generated(11)
    let second = generated(11)
    check first.groups == second.groups
    check first.matches == second.matches
    check generated(11).groups != generated(12).groups

  test "every pair is drawn exactly once":
    let tournament = generated(7)
    var drawn: seq[string] = @[]
    for groupId in GroupIds:
      check tournament.groups[ord(groupId)].len == GroupSize
      drawn.add tournament.groups[ord(groupId)]
    drawn.sort()
    var expected: seq[string] = @[]
    for pair in tournament.pairs:
      expected.add pair.id
    expected.sort()
    check drawn == expected

  test "the group schedule is the v1 round robin":
    let tournament = generated(7)
    let members = tournament.groups[ord(ga)]
    for index, slot in RoundRobin:
      let match = tournament.matches[index]
      check match.id == groupMatchId(ga, index)
      check match.phase == cpGroup
      check match.groupId == some(ga)
      check match.pairAId == some(members[slot[0]])
      check match.pairBId == some(members[slot[1]])
      check match.scoreA.isNone
      check match.scoreB.isNone
    check tournament.matches[5].id == "group-A-5"
    check tournament.matches[6].id == "group-B-0"
    check tournament.matches[23].id == "group-D-5"

  test "the knockout slots keep the v1 ids and order":
    let tournament = generated(7)
    let knockout = tournament.matches[24 .. ^1]
    var ids: seq[string] = @[]
    for match in knockout:
      ids.add match.id
    check ids == @["qf-1", "qf-2", "qf-3", "qf-4", "sf-1", "sf-2", "3rd-1",
      "final-1"]
    check tournament.matches[24].phase == cpQf
    check tournament.matches[28].phase == cpSf
    check tournament.matches[30].phase == cpThird
    check tournament.matches[31].phase == cpFinal

  test "the drawn bracket seeds the QF from group order":
    let tournament = generated(7)
    let a = tournament.groups[ord(ga)]
    let b = tournament.groups[ord(gb)]
    let c = tournament.groups[ord(gc)]
    let d = tournament.groups[ord(gd)]
    check byId(tournament, "qf-1").pairAId == some(a[0])
    check byId(tournament, "qf-1").pairBId == some(b[1])
    check byId(tournament, "qf-2").pairAId == some(c[1])
    check byId(tournament, "qf-2").pairBId == some(d[0])
    check byId(tournament, "qf-3").pairAId == some(c[0])
    check byId(tournament, "qf-3").pairBId == some(d[1])
    check byId(tournament, "qf-4").pairAId == some(a[1])
    check byId(tournament, "qf-4").pairBId == some(b[0])
    for id in ["sf-1", "sf-2", "3rd-1", "final-1"]:
      check byId(tournament, id).pairAId.isNone
      check byId(tournament, id).pairBId.isNone

  test "a draw needs exactly 16 pairs and a group exactly 4":
    var raised = false
    try:
      discard drawGroups(@["p1", "p2"], 1)
    except ValueError:
      raised = true
    check raised
    raised = false
    try:
      discard generateGroupMatches(ga, @["p1", "p2", "p3"])
    except ValueError:
      raised = true
    check raised

suite "bracket propagation":
  test "winners move on and semifinal losers meet for third":
    var tournament = scored([("qf-1", 30, 10), ("qf-2", 10, 30),
      ("qf-3", 30, 20), ("qf-4", 20, 30)])
    tournament = withPropagation(tournament)
    let qf1 = byId(tournament, "qf-1")
    let qf2 = byId(tournament, "qf-2")
    let qf3 = byId(tournament, "qf-3")
    let qf4 = byId(tournament, "qf-4")
    check byId(tournament, "sf-1").pairAId == qf1.pairAId
    check byId(tournament, "sf-1").pairBId == qf2.pairBId
    check byId(tournament, "sf-2").pairAId == qf3.pairAId
    check byId(tournament, "sf-2").pairBId == qf4.pairBId
    check byId(tournament, "final-1").pairAId.isNone
    check byId(tournament, "3rd-1").pairAId.isNone

    tournament.setScore("sf-1", 30, 10)
    tournament.setScore("sf-2", 10, 30)
    tournament = withPropagation(tournament)
    let sf1 = byId(tournament, "sf-1")
    let sf2 = byId(tournament, "sf-2")
    check byId(tournament, "final-1").pairAId == sf1.pairAId
    check byId(tournament, "final-1").pairBId == sf2.pairBId
    check byId(tournament, "3rd-1").pairAId == sf1.pairBId
    check byId(tournament, "3rd-1").pairBId == sf2.pairAId

  test "a changed feeder clears the downstream score":
    var tournament = scored([("qf-1", 30, 10), ("qf-2", 10, 30),
      ("qf-3", 30, 20), ("qf-4", 20, 30)])
    tournament = withPropagation(tournament)
    tournament.setScore("sf-1", 30, 10)
    tournament.setScore("sf-2", 30, 10)
    tournament = withPropagation(tournament)
    tournament.setScore("final-1", 30, 20)
    tournament = withPropagation(tournament)
    check byId(tournament, "final-1").scoreA == some(30)

    # Reverse qf-1: the sf-1 first slot changes, so its score must be dropped,
    # and the final loses its feeder entirely.
    tournament.setScore("qf-1", 10, 30)
    tournament = withPropagation(tournament)
    check byId(tournament, "sf-1").scoreA.isNone
    check byId(tournament, "sf-1").scoreB.isNone
    check byId(tournament, "final-1").pairAId.isNone
    check byId(tournament, "final-1").scoreA.isNone

  test "an unchanged pairing keeps its score":
    var tournament = scored([("qf-1", 30, 10)])
    tournament = withPropagation(tournament)
    check byId(tournament, "qf-1").scoreA == some(30)
    tournament = withPropagation(tournament)
    check byId(tournament, "qf-1").scoreA == some(30)

  test "a fully played bracket validates clean":
    var tournament = generated(7)
    for match in tournament.matches.mitems:
      if match.phase == cpGroup:
        match.scoreA = some(30)
        match.scoreB = some(20)
    tournament = withPropagation(tournament)
    for id in QfIds:
      tournament.setScore(id, 30, 20)
    tournament = withPropagation(tournament)
    for id in SfIds:
      tournament.setScore(id, 30, 20)
    tournament = withPropagation(tournament)
    tournament.setScore(FinalId, 30, 20)
    tournament.setScore(ThirdPlaceId, 20, 30)
    check validate(tournament).len == 0

suite "standings":
  test "wins, then difference, then points for":
    let matches = @[
      groupMatch("g1", "a", "b", 30, 10),
      groupMatch("g2", "c", "d", 30, 20)]
    let rows = computeGroupStandings(ga, @["a", "b", "c", "d"], matches)
    check rows.len == 4
    check rows[0].pairId == "a"
    check rows[1].pairId == "c"
    check rows[2].pairId == "d"
    check rows[3].pairId == "b"
    check rows[0].wins == 1
    check rows[0].losses == 0
    check rows[0].diff == 20
    check rows[0].pointsFor == 30
    check rows[3].diff == -20

  test "points for breaks a difference tie":
    let matches = @[
      groupMatch("g1", "a", "b", 30, 20),
      groupMatch("g2", "c", "d", 31, 21)]
    let rows = computeGroupStandings(ga, @["a", "b", "c", "d"], matches)
    check rows[0].pairId == "c"
    check rows[1].pairId == "a"
    check rows[0].diff == rows[1].diff
    check rows[0].pointsFor == 31

  test "head to head breaks a full tie":
    let matches = @[
      groupMatch("g1", "a", "b", 30, 20),
      groupMatch("g2", "b", "c", 20, 10),
      groupMatch("g3", "c", "a", 20, 10)]
    let rows = computeGroupStandings(ga, @["a", "b", "c", "d"], matches)
    check rows[0].pairId == "a"
    check rows[1].pairId == "b"
    check rows[2].pairId == "c"
    check rows[0].wins == rows[1].wins
    check rows[0].diff == rows[1].diff
    check rows[0].pointsFor == rows[1].pointsFor

  test "a full tie keeps the group input order":
    let rows = computeGroupStandings(ga, @["a", "b", "c", "d"], @[])
    for index, pairId in ["a", "b", "c", "d"]:
      check rows[index].pairId == pairId
      check rows[index].wins == 0
      check rows[index].pointsFor == 0

  test "unplayed and foreign-group matches count for nothing":
    let matches = @[
      groupMatch("g1", "a", "b", 30, 10),
      ClassicMatch(id: "g2", phase: cpGroup, groupId: some(gb),
        pairAId: some("c"), pairBId: some("d"),
        scoreA: some(30), scoreB: some(0)),
      ClassicMatch(id: "g3", phase: cpGroup, groupId: some(ga),
        pairAId: some("c"), pairBId: some("d"))]
    let rows = computeGroupStandings(ga, @["a", "b", "c", "d"], matches)
    check rows[1].pairId == "c"
    check rows[1].wins == 0
    check rows[1].pointsFor == 0

  test "the tournament wrapper reads its own group":
    var tournament = generated(7)
    let members = tournament.groups[ord(ga)]
    tournament.setScore(groupMatchId(ga, 0), 30, 10)
    let rows = computeStandings(tournament, ga)
    check rows.len == 4
    check rows[0].pairId == members[0]
    check rows[0].wins == 1

suite "classic validation":
  test "identity problems are reported":
    var tournament = generated(7)
    tournament.name = "  "
    check ciBlankName in kinds(validate(tournament))

    tournament = generated(7)
    tournament.date = ""
    check ciBlankDate in kinds(validate(tournament))

    tournament = generated(7)
    tournament.date = "2026-13-01"
    check ciInvalidDate in kinds(validate(tournament))

    tournament = generated(7)
    tournament.date = "2026-02-30"
    check ciInvalidDate in kinds(validate(tournament))

    tournament = generated(7)
    tournament.date = "2024-02-29"
    check ciInvalidDate notin kinds(validate(tournament))

  test "pair problems are reported":
    var tournament = generated(7)
    tournament.pairs.setLen(15)
    check ciPairCount in kinds(validate(tournament))

    tournament = generated(7)
    tournament.pairs[0].id = ""
    check ciBlankPairId in kinds(validate(tournament))

    tournament = generated(7)
    tournament.pairs[0].name = "   "
    check ciBlankPairName in kinds(validate(tournament))

    tournament = generated(7)
    tournament.pairs[1].id = tournament.pairs[0].id
    check ciDuplicatePairId in kinds(validate(tournament))

    # Two pairs that resolve to the same players put one player on both sides
    # of a match and doubled their games.
    tournament = generated(7)
    tournament.pairs[1].name = tournament.pairs[0].name
    check ciDuplicatePairName in kinds(validate(tournament))

    tournament = generated(7)
    tournament.pairs[1].name = "Player 2 & Player 5"
    check ciDuplicatePairPlayer in kinds(validate(tournament))

    tournament = generated(7)
    tournament.pairs[1].name = "Player 2 & Player 1"
    check ciDuplicatePairPlayer in kinds(validate(tournament))

    # A third name would be dropped by the resolver without a word.
    tournament = generated(7)
    tournament.pairs[0].name = "Player 1 & Player 2 & Player 3"
    check ciPairNameParts in kinds(validate(tournament))

  test "group problems are reported":
    var tournament = generated(7)
    tournament.groups[ord(ga)].setLen(3)
    check ciGroupSize in kinds(validate(tournament))

    tournament = generated(7)
    tournament.groups[ord(ga)][0] = "ghost"
    check ciUnknownGroupPair in kinds(validate(tournament))

    tournament = generated(7)
    tournament.groups[ord(ga)][0] = tournament.groups[ord(gb)][0]
    check ciDuplicateGroupPair in kinds(validate(tournament))

  test "match identity and phase counts are reported":
    var tournament = generated(7)
    tournament.matches.setLen(31)
    let missing = kinds(validate(tournament))
    check ciMatchCount in missing
    check ciPhaseCount in missing

    tournament = generated(7)
    tournament.matches[24].id = ""
    check ciBlankMatchId in kinds(validate(tournament))

    tournament = generated(7)
    tournament.matches[25].id = tournament.matches[24].id
    check ciDuplicateMatchId in kinds(validate(tournament))

    tournament = generated(7)
    tournament.matches[31].phase = cpGroup
    check ciPhaseCount in kinds(validate(tournament))

  test "pair references and self matches are reported":
    var tournament = generated(7)
    tournament.matches[0].pairAId = some("ghost")
    check ciPairReference in kinds(validate(tournament))

    tournament = generated(7)
    tournament.matches[0].pairBId = tournament.matches[0].pairAId
    check ciSelfMatch in kinds(validate(tournament))

  test "scores must be paired, non-negative, capped and decisive":
    var tournament = generated(7)
    tournament.matches[0].scoreA = some(30)
    check ciPartialScore in kinds(validate(tournament))

    tournament = generated(7)
    tournament.matches[0].scoreA = some(-1)
    tournament.matches[0].scoreB = some(30)
    check ciNegativeScore in kinds(validate(tournament))

    tournament = generated(7)
    tournament.matches[0].scoreA = some(100)
    tournament.matches[0].scoreB = some(30)
    check ciScoreTooHigh in kinds(validate(tournament))

    tournament = generated(7)
    tournament.matches[0].scoreA = some(30)
    tournament.matches[0].scoreB = some(30)
    check ciTiedMatch in kinds(validate(tournament))

  test "bracket progression mismatch is reported":
    var tournament = scored([("qf-1", 30, 10), ("qf-2", 10, 30),
      ("qf-3", 30, 20), ("qf-4", 20, 30)])
    tournament = withPropagation(tournament)
    check validate(tournament).len == 0

    let sf1 = byId(tournament, "sf-1")
    var wrong = ""
    for pairId in tournament.groups[ord(gd)]:
      if pairId != sf1.pairAId.get and pairId != sf1.pairBId.get:
        wrong = pairId
        break
    check wrong.len > 0
    for match in tournament.matches.mitems:
      if match.id == "sf-1":
        match.pairAId = some(wrong)
    check byId(tournament, "sf-1").pairAId.get != sf1.pairAId.get
    check ciBracketProgression in kinds(validate(tournament))
