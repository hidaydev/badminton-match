## Team tournament rules, frozen from v1.
##
## Sources: apps/api/internal/domain/{team_tournament,validate_team}.go plus the
## deleted web generator recovered from git history
## (00e2150^:apps/web/src/utils/teamTournament.ts). Frontend-only pieces —
## logos, photos, colours, canvas export — are not ported. The group schedule
## and day-of draw live in team_draw.

import std/[algorithm, options, strutils, tables, unicode]
import player/domain/player

type
  TeamClass* = enum
    tcAPlus = "A+"
    tcA = "A"
    tcBPlus = "B+"
    tcB = "B"
    tcCPlus = "C+"
    tcC = "C"

  TeamPhase* = enum
    tpGroup = "group"
    tpFinal = "final"

  TeamPlayer* = object
    name*: string
    cls*: TeamClass

  TeamInfo* = object
    id*: string
    name*: string
    players*: seq[TeamPlayer]

  TeamPartai* = object
    ## Both scores absent means the partai has not been played yet.
    scoreA*: Option[int]
    scoreB*: Option[int]

  TeamMatch* = object
    id*: string
    phase*: TeamPhase
    teamA*: string
    teamB*: string
    partai*: seq[TeamPartai]
    courts*: array[3, string]

  TeamTournament* = object
    version*: Option[int]
    name*: string
    date*: string
    teams*: seq[TeamInfo]
    matches*: seq[TeamMatch]

  TeamIssueKind* = enum
    tiBlankName = "blank_name"
    tiBlankDate = "blank_date"
    tiTeamCount = "team_count"
    tiBlankTeamId = "blank_team_id"
    tiDuplicateTeamId = "duplicate_team_id"
    tiBlankTeamName = "blank_team_name"
    tiUnknownTeamName = "unknown_team_name"
    tiDuplicateTeamName = "duplicate_team_name"
    tiRosterSize = "roster_size"
    tiBlankPlayerName = "blank_player_name"
    tiDuplicateClass = "duplicate_class"
    tiDuplicatePlayerName = "duplicate_player_name"
    tiBlankMatchId = "blank_match_id"
    tiDuplicateMatchId = "duplicate_match_id"
    tiTeamReference = "team_reference"
    tiSelfMatch = "self_match"
    tiPartaiCount = "partai_count"
    tiPartialScore = "partial_score"
    tiNegativeScore = "negative_score"
    tiTiedPartai = "tied_partai"
    tiGroupCount = "group_count"
    tiFinalCount = "final_count"
    tiGroupAppearances = "group_appearances"
    tiRepeatedPairing = "repeated_pairing"

  TeamIssue* = object
    kind*: TeamIssueKind
    detail*: string

  TeamOutcome* = object
    winsA*: int
    winsB*: int
    complete*: bool

  TeamStanding* = object
    teamId*: string
    teamName*: string
    played*: int
    ## Partai won/lost across team-matches (v1 `teamWins`/`teamLosses`), not
    ## team-match results; a swept team-match contributes 3 and 0.
    teamWins*: int
    teamLosses*: int
    points*: int
    pointsFor*: int
    pointsAgainst*: int

const
  # Six canonical team names; a tournament uses each exactly once.
  TeamNames* = ["RED RAPTORS", "WHITE FURY", "BLUE WAVES", "PURPLE PHANTOMS",
    "GREEN GROVE", "PINK SPECTRE"]

  TeamClasses* = [tcAPlus, tcA, tcBPlus, tcB, tcCPlus, tcC]

  # Partai 0 is C+/C, partai 1 is A+/A, partai 2 is B+/B.
  PartaiClasses* = [[tcCPlus, tcC], [tcAPlus, tcA], [tcBPlus, tcB]]

proc isTeamName*(name: string): bool =
  name.strip() in TeamNames

proc targetScore*(phase: TeamPhase): int =
  ## Rally target per phase: group 30, final 42. Scoring only, not a cap.
  if phase == tpFinal: 42 else: 30

proc classInPartai*(partaiIndex: int, cls: TeamClass): bool =
  ## True when a player of `cls` plays partai number `partaiIndex`.
  if partaiIndex < 0 or partaiIndex >= PartaiClasses.len:
    return false
  cls in PartaiClasses[partaiIndex]

proc partaiClassA*(partaiIndex: int): TeamClass =
  ## Upper-class half of a partai pair (C+/A+/B+ for 0/1/2).
  PartaiClasses[partaiIndex][0]

proc partaiClassB*(partaiIndex: int): TeamClass =
  ## Lower-class half of a partai pair (C/A/B for 0/1/2).
  PartaiClasses[partaiIndex][1]

proc addIssue(issues: var seq[TeamIssue], kind: TeamIssueKind,
              detail = "") =
  issues.add(TeamIssue(kind: kind, detail: detail))

proc validateRoster(players: seq[TeamPlayer], seenPlayers: var seq[string],
                    issues: var seq[TeamIssue]) =
  var classes: seq[TeamClass] = @[]
  for player in players:
    let name = player.name.strip()
    if name.len == 0:
      issues.addIssue(tiBlankPlayerName)
      continue
    if player.cls in classes:
      issues.addIssue(tiDuplicateClass, $player.cls)
    else:
      classes.add(player.cls)
    # Player names are unique across the whole tournament, not just the team.
    let key = normalizeName(name).toLower()
    if key in seenPlayers:
      issues.addIssue(tiDuplicatePlayerName, name)
    else:
      seenPlayers.add(key)

proc validateTeams(teams: seq[TeamInfo], seenPlayers: var seq[string],
                   issues: var seq[TeamIssue]) =
  var teamIds: seq[string] = @[]
  var teamNames: seq[string] = @[]
  for team in teams:
    if team.id.strip().len == 0:
      issues.addIssue(tiBlankTeamId)
    elif team.id in teamIds:
      issues.addIssue(tiDuplicateTeamId, team.id)
    else:
      teamIds.add(team.id)
    let name = team.name.strip()
    if name.len == 0:
      issues.addIssue(tiBlankTeamName)
    elif name notin TeamNames:
      issues.addIssue(tiUnknownTeamName, team.name)
    elif name in teamNames:
      issues.addIssue(tiDuplicateTeamName, name)
    else:
      teamNames.add(name)
    if team.players.len != 6:
      issues.addIssue(tiRosterSize, name & ": " & $team.players.len)
    validateRoster(team.players, seenPlayers, issues)

proc validatePartai(matchId: string, partai: TeamPartai,
                    issues: var seq[TeamIssue]) =
  if partai.scoreA.isNone and partai.scoreB.isNone:
    return
  if partai.scoreA.isNone or partai.scoreB.isNone:
    issues.addIssue(tiPartialScore, matchId)
    return
  let scoreA = partai.scoreA.get
  let scoreB = partai.scoreB.get
  # v1 accepts any decisive score (rally targets are advice, not a cap), so
  # only a negative value is structurally wrong.
  if scoreA < 0 or scoreB < 0:
    issues.addIssue(tiNegativeScore, matchId & ": " & $scoreA & "-" & $scoreB)
  if scoreA == scoreB:
    issues.addIssue(tiTiedPartai, matchId & ": " & $scoreA)

proc validateMatchTeams(match: TeamMatch, teamIds: seq[string],
                        issues: var seq[TeamIssue]) =
  if match.teamA.len == 0 or match.teamB.len == 0:
    issues.addIssue(tiTeamReference, match.id)
    return
  if match.teamA == match.teamB:
    issues.addIssue(tiSelfMatch, match.id)
  if match.teamA notin teamIds or match.teamB notin teamIds:
    issues.addIssue(tiTeamReference, match.id)

proc validateMatches(teams: seq[TeamInfo], matches: seq[TeamMatch],
                     issues: var seq[TeamIssue]) =
  var teamIds: seq[string] = @[]
  for team in teams:
    teamIds.add(team.id)
  var matchIds: seq[string] = @[]
  for match in matches:
    if match.id.strip().len == 0:
      issues.addIssue(tiBlankMatchId)
    elif match.id in matchIds:
      issues.addIssue(tiDuplicateMatchId, match.id)
    else:
      matchIds.add(match.id)
    validateMatchTeams(match, teamIds, issues)
    if match.partai.len != 3:
      issues.addIssue(tiPartaiCount, match.id)
    for partai in match.partai:
      validatePartai(match.id, partai, issues)

proc pairKey(a, b: string): string =
  ## Order-insensitive key, so A-B and B-A count as the same pairing.
  if a < b: a & "\x00" & b else: b & "\x00" & a

proc validateGroupDraw(teams: seq[TeamInfo], matches: seq[TeamMatch],
                       issues: var seq[TeamIssue]) =
  ## Group stage is either undrawn (0 team-matches) or the full nine, with each
  ## team appearing exactly three times and no repeated pairing. The fixed
  ## schedule that satisfies this lives in team_draw.generateGroupDraw.
  var groupCount = 0
  var finalCount = 0
  for match in matches:
    if match.phase == tpFinal: finalCount.inc else: groupCount.inc
  if finalCount > 1:
    issues.addIssue(tiFinalCount, $finalCount)
  if groupCount != 0 and groupCount != 9:
    issues.addIssue(tiGroupCount, $groupCount)
  var appearances = initCountTable[string]()
  var pairings: seq[string] = @[]
  for match in matches:
    if match.phase != tpGroup:
      continue
    appearances.inc(match.teamA)
    appearances.inc(match.teamB)
    let key = pairKey(match.teamA, match.teamB)
    if key in pairings:
      issues.addIssue(tiRepeatedPairing, match.teamA & " vs " & match.teamB)
    else:
      pairings.add(key)
  if groupCount != 9:
    return
  for team in teams:
    if appearances[team.id] != 3:
      issues.addIssue(tiGroupAppearances,
        team.name & ": " & $appearances[team.id])

proc validate*(tournament: TeamTournament): seq[TeamIssue] =
  ## Every structural rule from the v1 Go validator, accumulated instead of
  ## short-circuited so a caller can report all problems in one response.
  if tournament.name.strip().len == 0:
    result.addIssue(tiBlankName)
  if tournament.date.strip().len == 0:
    result.addIssue(tiBlankDate)
  if tournament.teams.len != 6:
    result.addIssue(tiTeamCount, $tournament.teams.len)
  var seenPlayers: seq[string] = @[]
  validateTeams(tournament.teams, seenPlayers, result)
  validateMatches(tournament.teams, tournament.matches, result)
  validateGroupDraw(tournament.teams, tournament.matches, result)

proc teamMatchOutcome*(match: TeamMatch): TeamOutcome =
  ## Partai won by each side; complete only when every partai has both scores.
  result.complete = true
  for partai in match.partai:
    if partai.scoreA.isNone or partai.scoreB.isNone:
      result.complete = false
      continue
    if partai.scoreA.get > partai.scoreB.get:
      result.winsA.inc
    elif partai.scoreB.get > partai.scoreA.get:
      result.winsB.inc

proc teamMatchPoints*(wins, losses: int): int =
  ## 3-0 = 3, 2-1 = 2, 1-2 = 1, 0-3 = 0. The v1 client owns this table and
  ## the final seeding; the backend only mirrors it for standings.
  if wins == 3: 3
  elif wins == 2: 2
  elif losses == 2: 1
  else: 0

proc compareStandings(a, b: TeamStanding): int =
  ## v1 order: points, then partai win-loss balance, then aggregate point
  ## difference. A full tie keeps team input order (the sort is stable), which
  ## is what the client's stable Array.sort did.
  result = cmp(b.points, a.points)
  if result != 0: return
  result = cmp(b.teamWins - b.teamLosses, a.teamWins - a.teamLosses)
  if result != 0: return
  result = cmp(b.pointsFor - b.pointsAgainst, a.pointsFor - a.pointsAgainst)

proc scoreSide(rows: var Table[string, TeamStanding], match: TeamMatch) =
  ## Adds one complete team-match to both rows. Unplayed partai are skipped, so
  ## a match only reaches here when the outcome is complete.
  var a = rows[match.teamA]
  var b = rows[match.teamB]
  let outcome = teamMatchOutcome(match)
  a.played.inc
  b.played.inc
  a.teamWins += outcome.winsA
  a.teamLosses += outcome.winsB
  b.teamWins += outcome.winsB
  b.teamLosses += outcome.winsA
  a.points += teamMatchPoints(outcome.winsA, outcome.winsB)
  b.points += teamMatchPoints(outcome.winsB, outcome.winsA)
  for partai in match.partai:
    if partai.scoreA.isNone or partai.scoreB.isNone:
      continue
    a.pointsFor += partai.scoreA.get
    a.pointsAgainst += partai.scoreB.get
    b.pointsFor += partai.scoreB.get
    b.pointsAgainst += partai.scoreA.get
  rows[match.teamA] = a
  rows[match.teamB] = b

proc computeStandings*(teams: seq[TeamInfo],
                       matches: seq[TeamMatch]): seq[TeamStanding] =
  ## Group standings for the matches the caller passes in. Undrawn or
  ## unfinished team-matches count for nothing, exactly like the v1 client.
  var rows = initTable[string, TeamStanding]()
  var order: seq[string] = @[]
  for team in teams:
    rows[team.id] = TeamStanding(teamId: team.id, teamName: team.name)
    order.add(team.id)
  for match in matches:
    if not teamMatchOutcome(match).complete:
      continue
    if not rows.hasKey(match.teamA) or not rows.hasKey(match.teamB):
      continue
    scoreSide(rows, match)
  for id in order:
    result.add(rows[id])
  result.sort(compareStandings)

proc champion*(tournament: TeamTournament): Option[string] =
  ## Winner of the single final team-match once every partai is scored. v1
  ## resolves an impossible partai tie (three partai cannot split evenly) in
  ## favour of teamB; validation is the gate that keeps such input out.
  for match in tournament.matches:
    if match.phase != tpFinal:
      continue
    let outcome = teamMatchOutcome(match)
    if not outcome.complete:
      return none(string)
    if outcome.winsA > outcome.winsB:
      return some(match.teamA)
    return some(match.teamB)
  none(string)
