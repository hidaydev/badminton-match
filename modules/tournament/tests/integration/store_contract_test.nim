## The tournament store edges BE-15 names: format filters and limit bounds,
## a finalised source that refuses both writes, the removal contract when a
## rating event still names the tournament, a team roster replace, and the
## invalid-input path. Needs MAJADU_PG_DSN.

import std/[json, options, os, strutils, unittest]
import db/db
import tests/fixtures
import tournament/store
import tournament/domain/classic
import tournament/domain/classic_draw
import tournament/domain/team
import tournament/domain/team_draw

const slug = "be15-tournament-store"

proc classicJson(data: ClassicTournament): JsonNode =
  var pairs = newJArray()
  for pair in data.pairs:
    pairs.add(%*{"id": pair.id, "name": pair.name})
  var groups = newJObject()
  for groupId in GroupIds:
    var members = newJArray()
    for pairId in data.groups[ord(groupId)]:
      members.add(%pairId)
    groups[$groupId] = members
  var matches = newJArray()
  for match in data.matches:
    matches.add(%*{
      "id": match.id, "phase": $match.phase,
      "groupId": if match.groupId.isSome: %($match.groupId.get) else: newJNull(),
      "pairAId": if match.pairAId.isSome: %match.pairAId.get else: newJNull(),
      "pairBId": if match.pairBId.isSome: %match.pairBId.get else: newJNull(),
      "scoreA": if match.scoreA.isSome: %match.scoreA.get else: newJNull(),
      "scoreB": if match.scoreB.isSome: %match.scoreB.get else: newJNull()})
  %*{"name": data.name, "date": data.date, "pairs": pairs, "groups": groups,
     "matches": matches}

proc teamJson(data: TeamTournament): JsonNode =
  var teams = newJArray()
  for team in data.teams:
    var players = newJArray()
    for player in team.players:
      players.add(%*{"name": player.name, "cls": $player.cls})
    teams.add(%*{"id": team.id, "name": team.name, "players": players})
  var matches = newJArray()
  for match in data.matches:
    var partai = newJArray()
    for entry in match.partai:
      partai.add(%*{
        "scoreA": if entry.scoreA.isSome: %entry.scoreA.get else: newJNull(),
        "scoreB": if entry.scoreB.isSome: %entry.scoreB.get else: newJNull()})
    matches.add(%*{"id": match.id, "phase": $match.phase,
      "teamA": match.teamA, "teamB": match.teamB, "partai": partai,
      "courts": %*[match.courts[0], match.courts[1], match.courts[2]]})
  %*{"format": "team", "name": data.name, "date": data.date, "teams": teams,
     "matches": matches}

proc classicSnapshot(name = "Autumn Cup", date = "2026-11-04"): ClassicTournament =
  var pairs: seq[Pair] = @[]
  for index in 1 .. 16:
    pairs.add(Pair(id: "p" & $index,
      name: "Player " & $(index * 2 - 1) & " & Player " & $(index * 2)))
  generateTournament(name, date, pairs, 7)

proc teamSnapshot(): TeamTournament =
  var ids: seq[string] = @[]
  for index, name in TeamNames:
    var team = TeamInfo(id: "t" & $(index + 1), name: name)
    for offset, cls in TeamClasses:
      team.players.add(TeamPlayer(name: name & " P" & $(offset + 1), cls: cls))
    result.teams.add(team)
    ids.add(team.id)
  result.name = "Team Cup"
  result.date = "2026-11-05"
  result.matches = drawGroupMatches(ids)
  result.matches.add(finalMatch(ids[0], ids[1]))

proc clearRows(database: Db, communityId: string) =
  ## Scoped to the suite's own community, children before parents.
  for statement in [
      "delete from tournament.team_partai where community_id = $1::uuid",
      "delete from tournament.team_matches where community_id = $1::uuid",
      "delete from tournament.team_players where community_id = $1::uuid",
      "delete from tournament.teams where community_id = $1::uuid",
      "delete from tournament.groups where community_id = $1::uuid",
      "delete from tournament.matches where community_id = $1::uuid",
      "delete from tournament.pairs where community_id = $1::uuid",
      "delete from tournament.tournaments where community_id = $1::uuid",
      "delete from rating.events where community_id = $1::uuid",
      "delete from rating.sources where community_id = $1::uuid"]:
    discard database.execUpdate(statement, @[textParam(communityId)])

proc header(database: Db, communityId, id: string): Option[Row] =
  database.queryOne(
    """select name, version, event_date::text as date
       from tournament.tournaments
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(id)])

if getEnv("MAJADU_PG_DSN").len == 0:
  raise newException(ValueError, "MAJADU_PG_DSN is required")

let database = openDb(getEnv("MAJADU_PG_DSN"), 2)
purgeCommunity(database, slug)
let communityId = newCommunity(database, slug, "BE15 Tournament Store")

suite "tournament store contract":
  test "list filters by format and clamps both bounds":
    clearRows(database, communityId)
    let (older, _) = create(database, communityId, "",
      classicJson(classicSnapshot("Older Classic", "2026-01-01")))
    check older == svOk
    let (newer, _) = create(database, communityId, "",
      classicJson(classicSnapshot("Newer Classic", "2026-01-02")))
    check newer == svOk
    let (team, _) = create(database, communityId, "",
      teamJson(teamSnapshot()))
    check team == svOk

    let classic = list(database, communityId, "classic", 100, 0)
    check classic.len == 2
    for row in classic:
      check row["format"].getStr() == "classic"
    # Ordered by event_date desc, so the newer classic is the first page.
    check classic[0]["name"].getStr() == "Newer Classic"
    check classic[1]["name"].getStr() == "Older Classic"

    let teamRows = list(database, communityId, "team", 100, 0)
    check teamRows.len == 1
    check teamRows[0]["format"].getStr() == "team"

    # An unknown format is not a filter, it returns every format.
    check list(database, communityId, "bogus", 100, 0).len == 3

    # 105 header rows with distinct dates make both clamps observable.
    discard database.execUpdate(
      """insert into tournament.tournaments
           (community_id, name, event_date, format, version, status)
         select $1::uuid, 'Bulk ' || i, date '2026-02-01' + i,
                'classic', 1, 'draft'
         from generate_series(1, 105) as i""",
      @[textParam(communityId)])

    # limit is pulled into 1..100: 1000 becomes 100, 0 and -5 become 1.
    check list(database, communityId, "classic", 1000, 0).len == 100
    check list(database, communityId, "classic", 0, 0).len == 1
    check list(database, communityId, "classic", -5, 0).len == 1
    # offset is pulled up to 0, so a negative offset is the first page.
    let firstPage = list(database, communityId, "classic", 100, 0)
    let negative = list(database, communityId, "classic", 100, -10)
    check negative.len == firstPage.len
    for index in 0 ..< firstPage.len:
      check negative[index]["id"].getStr() == firstPage[index]["id"].getStr()

    discard database.execUpdate(
      """delete from tournament.tournaments
         where community_id = $1::uuid and name like 'Bulk %'""",
      @[textParam(communityId)])

  test "a finalised source refuses replace and patch without writing":
    clearRows(database, communityId)
    let (created, snapshot) = create(database, communityId, "",
      classicJson(classicSnapshot()))
    check created == svOk
    let id = snapshot["id"].getStr()
    let before = load(database, communityId, id).get
    discard database.execUpdate(
      """insert into rating.sources (community_id, source_id, kind, finalized)
         values ($1::uuid, $2::uuid, 'tournament', true)""",
      @[textParam(communityId), textParam(id)])

    var rename = before
    rename["name"] = %"Locked Rename"
    let (replaced, detail) = replace(database, communityId, id, "", rename, 1)
    check replaced == svLocked
    check detail.len == 0
    var stored = header(database, communityId, id).get
    check stored.get("name") == "Autumn Cup"
    check stored.getInt("version") == 1

    let target = before["matches"][0]
    let matchId = target["id"].getStr()
    let (patched, patchDetail) = patchMatch(database, communityId, id, matchId,
      %*{"scoreA": 21, "scoreB": 15}, 1)
    check patched == ptLocked
    check patchDetail.len == 0
    stored = header(database, communityId, id).get
    check stored.getInt("version") == 1
    let after = load(database, communityId, id).get
    check after["name"].getStr() == "Autumn Cup"
    for match in after["matches"]:
      if match["id"].getStr() == matchId:
        check match["scoreA"].kind == JNull
        check match["scoreB"].kind == JNull

  test "remove drops the tournament and its rating event":
    clearRows(database, communityId)
    let (created, snapshot) = create(database, communityId, "",
      classicJson(classicSnapshot("Orphan Cup", "2026-11-07")))
    check created == svOk
    let id = snapshot["id"].getStr()
    discard database.execUpdate(
      """insert into rating.events (community_id, local_date, event_type, source_id)
         values ($1::uuid, '2026-11-07', 'tournament', $2::uuid)""",
      @[textParam(communityId), textParam(id)])

    check remove(database, communityId, id)
    check load(database, communityId, id).isNone
    check header(database, communityId, id).isNone
    # The source trigger removes the event with the tournament, so no row keeps
    # naming an id that no longer exists.
    let event = database.queryOne(
      """select source_id::text as source_id from rating.events
         where community_id = $1::uuid and source_id = $2::uuid""",
      @[textParam(communityId), textParam(id)])
    check event.isNone

  test "a team replace writes the new roster and keeps the tournament id":
    clearRows(database, communityId)
    let (created, snapshot) = create(database, communityId, "",
      teamJson(teamSnapshot()))
    check created == svOk
    let id = snapshot["id"].getStr()
    var first = load(database, communityId, id).get
    check first["teams"].len == 6
    let team0 = first["teams"].elems[0]
    let teamId = team0["id"].getStr()
    let originalName = team0["players"].elems[0]["name"].getStr()
    let replacement = "Roster New " & id[^4 .. ^1]
    team0["players"].elems[0] = %*{"name": replacement, "cls": "A+"}

    let (replaced, second) = replace(database, communityId, id, "", first, 1)
    check replaced == svOk
    check second["id"].getStr() == id
    check second["version"].getInt() == 2

    let roster = database.query(
      """select player_name from tournament.team_players
         where community_id = $1::uuid and team_id = $2::uuid""",
      @[textParam(communityId), textParam(teamId)])
    check roster.len == 6
    var names: seq[string] = @[]
    for row in roster:
      names.add(row.get("player_name"))
    check replacement in names
    check originalName notin names
    check header(database, communityId, id).get.getInt("version") == 2

  test "a malformed date or blank name is an issue, not a database error":
    clearRows(database, communityId)

    var badDate = teamJson(teamSnapshot())
    badDate["date"] = %"2026-13-45"
    let (dateStatus, dateDetail) = create(database, communityId, "", badDate)
    check dateStatus == svInvalid
    check dateDetail["issues"][0]["kind"].getStr() == "invalid_body"
    check dateDetail["issues"][0]["detail"].getStr().contains("date")

    var blankName = classicJson(classicSnapshot())
    blankName["name"] = %"   "
    let (nameStatus, nameDetail) = create(database, communityId, "", blankName)
    check nameStatus == svInvalid
    check nameDetail["issues"][0]["kind"].getStr() == "blank_name"

    var badClassicDate = classicJson(classicSnapshot())
    badClassicDate["date"] = %"2026-02-31"
    let (classicStatus, classicDetail) =
      create(database, communityId, "", badClassicDate)
    check classicStatus == svInvalid
    check classicDetail["issues"][0]["kind"].getStr() == "invalid_date"

    # None of the three reached a write.
    check database.queryOne(
      """select count(*)::int as n from tournament.tournaments
         where community_id = $1::uuid""",
      @[textParam(communityId)]).get.get("n") == "0"

clearRows(database, communityId)
purgeCommunity(database, slug)
database.close()