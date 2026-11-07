import std/[options, unittest]
import ../domain/team
import ../domain/team_draw

proc roster(prefix: string): seq[TeamPlayer] =
  for cls in TeamClasses:
    result.add(TeamPlayer(name: prefix & " " & $cls, cls: cls))

proc teamAt(index: int): TeamInfo =
  TeamInfo(id: "t" & $index, name: TeamNames[index],
    players: roster(TeamNames[index]))

proc allTeams(): seq[TeamInfo] =
  for index in 0 ..< TeamNames.len:
    result.add(teamAt(index))

proc teamIds(teams: seq[TeamInfo]): seq[string] =
  for team in teams:
    result.add(team.id)

proc snapshot(): TeamTournament =
  TeamTournament(name: "Anniversary Cup", date: "2026-11-04",
    teams: allTeams())

proc played(a, b: int): TeamPartai =
  TeamPartai(scoreA: some(a), scoreB: some(b))

proc blank(): TeamPartai = TeamPartai()

proc makeMatch(id, teamA, teamB: string, partai: seq[TeamPartai],
               phase = tpGroup): TeamMatch =
  TeamMatch(id: id, phase: phase, teamA: teamA, teamB: teamB,
    partai: partai, courts: ["Court 12", "Court 12", "Court 12"])

proc kinds(issues: seq[TeamIssue]): seq[TeamIssueKind] =
  for issue in issues:
    result.add(issue.kind)

proc blankPartai(): seq[TeamPartai] = newSeq[TeamPartai](3)

suite "team classes and targets":
  test "six canonical names, used once each":
    check TeamNames.len == 6
    for index in 0 ..< TeamNames.len:
      for other in index + 1 ..< TeamNames.len:
        check TeamNames[index] != TeamNames[other]
    check isTeamName("RED RAPTORS")
    check isTeamName(" WHITE FURY ")
    check not isTeamName("red raptors")
    check not isTeamName("TEAM SEVEN")

  test "classes and the partai mapping are fixed":
    check TeamClasses == [tcAPlus, tcA, tcBPlus, tcB, tcCPlus, tcC]
    check partaiClassA(0) == tcCPlus
    check partaiClassB(0) == tcC
    check partaiClassA(1) == tcAPlus
    check partaiClassB(1) == tcA
    check partaiClassA(2) == tcBPlus
    check partaiClassB(2) == tcB
    for index in 0 .. 2:
      check classInPartai(index, partaiClassA(index))
      check classInPartai(index, partaiClassB(index))
    check not classInPartai(0, tcAPlus)
    check not classInPartai(-1, tcC)
    check not classInPartai(3, tcC)

  test "the string mapping follows the partai constants":
    for index in 0 .. 2:
      let expected = @[$partaiClassA(index), $partaiClassB(index)]
      check partaiClasses(index) == expected
    check partaiClasses(0) == @["C+", "C"]
    check partaiClasses(1) == @["A+", "A"]
    check partaiClasses(2) == @["B+", "B"]
    check partaiClasses(-1).len == 0
    check partaiClasses(3).len == 0

  test "a side is the roster slots whose class plays the partai":
    let roster = @[("C+", "p1"), ("C", "p2"), ("A+", "p3"), ("A", "p4"),
      ("B+", "p5"), ("B", "p6")]
    check sideForPartai(roster, 0) == @["p1", "p2"]
    check sideForPartai(roster, 1) == @["p3", "p4"]
    check sideForPartai(roster, 2) == @["p5", "p6"]
    check sideForPartai(roster, -1).len == 0
    check sideForPartai(roster, 3).len == 0
    let empty: seq[(string, string)] = @[]
    check sideForPartai(empty, 0).len == 0

  test "rally target is 30 in the group and 42 in the final":
    check targetScore(tpGroup) == 30
    check targetScore(tpFinal) == 42

suite "team validation":
  test "the canonical six-team snapshot is valid":
    check validate(snapshot()).len == 0

  test "the generated draw validates against the group rules":
    var snap = snapshot()
    snap.matches = drawGroupMatches(teamIds(snap.teams))
    check validate(snap).len == 0

  test "identity problems are reported":
    var snap = snapshot()
    snap.name = " "
    snap.date = ""
    check tiBlankName in kinds(validate(snap))
    check tiBlankDate in kinds(validate(snap))

    snap = snapshot()
    snap.teams.setLen(5)
    check tiTeamCount in kinds(validate(snap))

    snap = snapshot()
    snap.teams[1].name = "TEAM SEVEN"
    check tiUnknownTeamName in kinds(validate(snap))

    snap = snapshot()
    snap.teams[1].name = TeamNames[0]
    check tiDuplicateTeamName in kinds(validate(snap))

    snap = snapshot()
    snap.teams[1].id = snap.teams[0].id
    check tiDuplicateTeamId in kinds(validate(snap))

    snap = snapshot()
    snap.teams[0].id = ""
    check tiBlankTeamId in kinds(validate(snap))

  test "roster problems are reported":
    var snap = snapshot()
    snap.teams[0].players.setLen(5)
    check tiRosterSize in kinds(validate(snap))

    snap = snapshot()
    snap.teams[0].players[1].cls = tcAPlus
    check tiDuplicateClass in kinds(validate(snap))

    snap = snapshot()
    snap.teams[1].players[0].name = snap.teams[0].players[0].name
    check tiDuplicatePlayerName in kinds(validate(snap))

    snap = snapshot()
    snap.teams[0].players[0].name = "  "
    check tiBlankPlayerName in kinds(validate(snap))

  test "match structure and scores are guarded":
    var snap = snapshot()
    snap.matches = @[makeMatch("", "t0", "t1", blankPartai())]
    check tiBlankMatchId in kinds(validate(snap))

    snap = snapshot()
    snap.matches = @[makeMatch("m1", "t0", "t1", blankPartai()),
      makeMatch("m1", "t2", "t3", blankPartai())]
    check tiDuplicateMatchId in kinds(validate(snap))

    snap = snapshot()
    snap.matches = @[makeMatch("m1", "t0", "t9", blankPartai())]
    check tiTeamReference in kinds(validate(snap))

    snap = snapshot()
    snap.matches = @[makeMatch("m1", "t0", "t0", blankPartai())]
    check tiSelfMatch in kinds(validate(snap))

    snap = snapshot()
    snap.matches = @[makeMatch("m1", "t0", "t1", @[blank(), blank()])]
    check tiPartaiCount in kinds(validate(snap))

  test "partai scores must be paired, non-negative and decisive":
    var snap = snapshot()
    snap.matches = @[makeMatch("m1", "t0", "t1",
      @[TeamPartai(scoreA: some(30)), blank(), blank()])]
    check tiPartialScore in kinds(validate(snap))

    snap = snapshot()
    snap.matches = @[makeMatch("m1", "t0", "t1",
      @[played(-1, 0), blank(), blank()])]
    check tiNegativeScore in kinds(validate(snap))

    # Target scores are advice, not a cap: 42 is legal in a group match.
    snap = snapshot()
    snap.matches = @[makeMatch("m1", "t0", "t1",
      @[played(42, 40), blank(), blank()])]
    check tiNegativeScore notin kinds(validate(snap))

    snap = snapshot()
    snap.matches = @[makeMatch("m1", "t0", "t1",
      @[played(30, 30), blank(), blank()])]
    check tiTiedPartai in kinds(validate(snap))

  test "group shape: nine matches, three per team, no repeat pairing":
    var snap = snapshot()
    snap.matches = drawGroupMatches(teamIds(snap.teams))
    snap.matches.setLen(8)
    check tiGroupCount in kinds(validate(snap))

    snap = snapshot()
    snap.matches = drawGroupMatches(teamIds(snap.teams))
    snap.matches[1] = makeMatch("g-2", "t0", "t1", blankPartai())
    check tiRepeatedPairing in kinds(validate(snap))

    snap = snapshot()
    snap.matches = drawGroupMatches(teamIds(snap.teams))
    snap.matches[8] = makeMatch("g-9", "t1", "t3", blankPartai())
    let issues = kinds(validate(snap))
    check tiGroupAppearances in issues
    check tiRepeatedPairing notin issues

  test "at most one final":
    var snap = snapshot()
    snap.matches = @[makeMatch("f1", "t0", "t1", blankPartai(), tpFinal),
      makeMatch("f2", "t2", "t3", blankPartai(), tpFinal)]
    check tiFinalCount in kinds(validate(snap))

suite "standings":
  test "match points follow the v1 table":
    check teamMatchPoints(3, 0) == 3
    check teamMatchPoints(2, 1) == 2
    check teamMatchPoints(1, 2) == 1
    check teamMatchPoints(0, 3) == 0

  test "outcome counts partai wins and marks incomplete matches":
    let complete = makeMatch("m", "t0", "t1",
      @[played(30, 10), played(30, 20), played(20, 30)])
    let outcome = teamMatchOutcome(complete)
    check outcome.winsA == 2
    check outcome.winsB == 1
    check outcome.complete

    let partial = makeMatch("m", "t0", "t1",
      @[played(30, 10), blank(), blank()])
    check not teamMatchOutcome(partial).complete

  test "played, partai record, points and aggregate points":
    let teams = allTeams()
    let matches = @[
      makeMatch("m1", "t0", "t1",
        @[played(30, 10), played(30, 20), played(20, 30)]),
      makeMatch("m2", "t2", "t3",
        @[played(30, 0), played(30, 0), played(30, 0)]),
      makeMatch("m3", "t4", "t5",
        @[played(30, 0), blank(), blank()])]
    let rows = computeStandings(teams, matches)
    check rows.len == 6
    check rows[0].teamId == "t2"
    check rows[1].teamId == "t0"
    check rows[2].teamId == "t1"
    check rows[3].teamId == "t4"
    check rows[4].teamId == "t5"
    check rows[5].teamId == "t3"

    check rows[1].played == 1
    check rows[1].teamWins == 2
    check rows[1].teamLosses == 1
    check rows[1].points == 2
    check rows[1].pointsFor == 80
    check rows[1].pointsAgainst == 60
    check rows[2].teamWins == 1
    check rows[2].points == 1
    check rows[3].played == 0
    check rows[3].pointsFor == 0

  test "a full tie keeps team input order":
    let rows = computeStandings(allTeams(), @[])
    for index in 0 ..< rows.len:
      check rows[index].teamId == "t" & $index

  test "win-loss balance breaks a points tie":
    # t0: sweep then swept (3 points, balance 0); t1: one sweep (3 points,
    # balance 3) — the balance ranks t1 first.
    let matches = @[
      makeMatch("m1", "t0", "t2",
        @[played(30, 0), played(30, 0), played(30, 0)]),
      makeMatch("m2", "t3", "t0",
        @[played(30, 0), played(30, 0), played(30, 0)]),
      makeMatch("m3", "t1", "t4",
        @[played(30, 0), played(30, 0), played(30, 0)])]
    let rows = computeStandings(allTeams(), matches)
    check rows[0].teamId == "t1"
    check rows[1].teamId == "t3"
    check rows[2].teamId == "t0"
    check rows[0].points == rows[2].points

  test "aggregate point difference breaks the next tie":
    # Both sweep once with the same balance, but t0 scores 90 for 60 against
    # and t1 scores 60 for 30: same difference, more points for wins.
    let matches = @[
      makeMatch("m1", "t0", "t4",
        @[played(30, 20), played(30, 20), played(30, 20)]),
      makeMatch("m2", "t1", "t5",
        @[played(20, 10), played(20, 10), played(20, 10)])]
    let rows = computeStandings(allTeams(), matches)
    check rows[0].teamId == "t0"
    check rows[1].teamId == "t1"
    check rows[0].points == rows[1].points
    check rows[0].pointsFor == 90
    check rows[1].pointsFor == 60

suite "group draw":
  test "nine matches, three sessions, three courts":
    let draw = generateGroupDraw(teamIds(allTeams()))
    check draw.len == 9
    check draw[0].teamA == "t0"
    check draw[0].teamB == "t1"
    check draw[0].court == "Court 12"
    check draw[1].court == "Court 13"
    check draw[2].court == "Court 14"
    check draw[3].teamA == "t3"
    check draw[3].teamB == "t5"
    check draw[8].teamA == "t0"
    check draw[8].teamB == "t3"
    var appearances = [0, 0, 0, 0, 0, 0]
    for item in draw:
      appearances[item.teamA[1].ord - '0'.ord].inc
      appearances[item.teamB[1].ord - '0'.ord].inc
    for count in appearances:
      check count == 3

  test "a draw needs exactly six teams":
    var raised = false
    try:
      discard generateGroupDraw(@["t0", "t1"])
    except ValueError:
      raised = true
    check raised

  test "the draw produces unscored matches with one court each":
    let matches = drawGroupMatches(teamIds(allTeams()))
    check matches.len == 9
    for index, match in matches:
      check match.id == "g-" & $(index + 1)
      check match.phase == tpGroup
      check match.partai.len == 3
      check match.courts[0] == match.courts[1]
      check match.courts[1] == match.courts[2]
      for partai in match.partai:
        check partai.scoreA.isNone
        check partai.scoreB.isNone

  test "the final is one unscored team-match on Court 12":
    let final = finalMatch("t0", "t1")
    check final.id == "final"
    check final.phase == tpFinal
    check final.teamA == "t0"
    check final.teamB == "t1"
    check final.partai.len == 3
    check final.courts == ["Court 12", "Court 12", "Court 12"]

  test "the day-of draw moves the whole entry to its slot":
    let drawn = buildTeamsByDraw(allTeams(), @[5, 4, 3, 2, 1, 0])
    check drawn.len == 6
    check drawn[0].id == "t1"
    check drawn[0].name == TeamNames[5]
    check drawn[0].players.len == 6
    check drawn[0].players[0].name == TeamNames[5] & " A+"
    check drawn[5].name == TeamNames[0]

    let skipped = buildTeamsByDraw(allTeams(), @[0, 9])
    check skipped.len == 1
    check skipped[0].name == TeamNames[0]

  test "the champion is the final winner":
    var snap = snapshot()
    snap.matches = @[makeMatch("final", "t2", "t3",
      @[played(42, 30), played(30, 42), played(42, 30)], tpFinal)]
    check champion(snap).get == "t2"

    snap.matches = @[makeMatch("final", "t2", "t3",
      @[played(30, 42), played(30, 42), played(42, 30)], tpFinal)]
    check champion(snap).get == "t3"

    snap.matches = @[makeMatch("final", "t2", "t3",
      @[played(42, 30), blank(), blank()], tpFinal)]
    check champion(snap).isNone

    snap.matches = @[]
    check champion(snap).isNone

suite "editor diffing":
  test "court and score changes mark a match dirty":
    let server = makeMatch("m1", "t0", "t1",
      @[played(30, 10), blank(), blank()])
    check teamMatchDirty(server, none(TeamMatch))
    check not teamMatchDirty(server, some(server))

    var local = server
    local.courts[0] = "Court 9"
    check teamMatchDirty(local, some(server))

    local = server
    local.partai[0] = played(30, 11)
    check teamMatchDirty(local, some(server))

    local = server
    local.partai.setLen(2)
    check teamMatchDirty(local, some(server))
