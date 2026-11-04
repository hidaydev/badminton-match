## Integration test for tournament/store: both formats write, read back,
## replace, patch one match and delete. Skips without MAJADU_PG_DSN.

import std/[json, options, os, strutils, unittest]
import db/db
import tournament/store
import tournament/domain/classic
import tournament/domain/classic_draw
import tournament/domain/team
import tournament/domain/team_draw

const slug = "tour-store-test"

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

proc pairNameMap(pairs: JsonNode): JsonNode =
  result = newJObject()
  for pair in pairs:
    result[pair["id"].getStr()] = pair["name"]

proc refName(mapping: JsonNode, node: JsonNode): string =
  if node.kind == JNull: "" else: mapping[node.getStr()].getStr()

proc cleanup(database: Db) =
  const statements = [
    """delete from tournament.team_partai where community_id in
         (select id from platform.community where slug = $1)""",
    """delete from tournament.team_matches where community_id in
         (select id from platform.community where slug = $1)""",
    """delete from tournament.team_players where community_id in
         (select id from platform.community where slug = $1)""",
    """delete from tournament.teams where community_id in
         (select id from platform.community where slug = $1)""",
    """delete from tournament.groups where community_id in
         (select id from platform.community where slug = $1)""",
    """delete from tournament.matches where community_id in
         (select id from platform.community where slug = $1)""",
    """delete from tournament.pairs where community_id in
         (select id from platform.community where slug = $1)""",
    """delete from tournament.tournaments where community_id in
         (select id from platform.community where slug = $1)""",
    """delete from player.players where community_id in
         (select id from platform.community where slug = $1)""",
    "delete from platform.community where slug = $1"]
  for statement in statements:
    discard database.execUpdate(statement, @[textParam(slug)])

proc classicSnapshot(): ClassicTournament =
  var pairs: seq[Pair] = @[]
  for index in 1 .. 16:
    pairs.add(Pair(id: "p" & $index,
      name: "Player " & $(index * 2 - 1) & " & Player " & $(index * 2)))
  generateTournament("Autumn Cup", "2026-11-04", pairs, 7)

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

proc count(database: Db, table: string): int =
  parseInt(database.queryOne("select count(*)::int as n from " & table &
    " where community_id in (select id from platform.community where slug = $1)",
    @[textParam(slug)]).get.get("n"))

if getEnv("MAJADU_PG_DSN").len == 0:
  echo "tournament store test skipped: MAJADU_PG_DSN is not set"
  quit(QuitSuccess)

let database = openDb(getEnv("MAJADU_PG_DSN"), 2)
cleanup(database)
let communityId = database.queryOne(
  """insert into platform.community (slug, name, timezone)
     values ($1, 'Tournament Store', 'Asia/Jakarta') returning id""",
  @[textParam(slug)]).get.get("id")

suite "tournament store":
  test "classic creates, round-trips, replaces, patches and deletes":
    let body = classicJson(classicSnapshot())
    let (created, snapshot) = create(database, communityId, "", body)
    check created == svOk
    let id = snapshot["id"].getStr()
    let first = load(database, communityId, id).get
    check first["format"].getStr() == "classic"
    check first["pairs"].len == 16
    check first["matches"].len == 32
    let firstNames = pairNameMap(first["pairs"])
    let bodyNames = pairNameMap(body["pairs"])
    for index in 0 ..< 32:
      let stored = first["matches"][index]
      let sent = body["matches"][index]
      check stored["phase"].getStr() == sent["phase"].getStr()
      check refName(firstNames, stored["pairAId"]) ==
        refName(bodyNames, sent["pairAId"])
      check refName(firstNames, stored["pairBId"]) ==
        refName(bodyNames, sent["pairBId"])
    for groupId in GroupIds:
      check first["groups"][$groupId].len == 4

    # load -> replace keeps every child row and only bumps the version.
    let (replaced, second) = replace(database, communityId, id, "", first, 1)
    check replaced == svOk
    check second["version"].getInt() == 2
    check second["pairs"] == first["pairs"]
    check second["groups"] == first["groups"]
    check second["matches"] == first["matches"]

    var changed = second
    changed["name"] = %"Autumn Cup Renamed"
    let (renamed, third) = replace(database, communityId, id, "", changed, 2)
    check renamed == svOk
    check third["name"].getStr() == "Autumn Cup Renamed"
    let (stale, _) = replace(database, communityId, id, "", changed, 2)
    check stale == svStale

    let before = load(database, communityId, id).get
    let target = before["matches"][0]["id"].getStr()
    let (patched, after) = patchMatch(database, communityId, id, target,
      %*{"scoreA": 21, "scoreB": 15}, 3)
    check patched == ptOk
    check after["version"].getInt() == 4
    for index in 0 ..< before["matches"].len:
      let row = after["matches"][index]
      if row["id"].getStr() == target:
        check row["scoreA"].getInt() == 21
        check row["scoreB"].getInt() == 15
      else:
        check row == before["matches"][index]

    check remove(database, communityId, id)
    check load(database, communityId, id).isNone
    check count(database, "tournament.matches") == 0
    check count(database, "tournament.pairs") == 0

  test "team creates, round-trips and patches one partai":
    let body = teamJson(teamSnapshot())
    let (created, snapshot) = create(database, communityId, "", body)
    check created == svOk
    let id = snapshot["id"].getStr()
    let first = load(database, communityId, id).get
    check first["format"].getStr() == "team"
    check first["teams"].len == 6
    check first["teams"][0]["players"].len == 6
    check first["matches"].len == 10
    check first["matches"][0]["partai"].len == 3

    let (replaced, second) = replace(database, communityId, id, "", first, 1)
    check replaced == svOk
    check second["teams"] == first["teams"]
    check second["matches"] == first["matches"]

    let before = load(database, communityId, id).get
    let target = before["matches"][0]["id"].getStr()
    let (patched, after) = patchMatch(database, communityId, id, target, %*{
      "courts": ["Court 1", "Court 2", "Court 3"],
      "partai": [
        {"scoreA": 30, "scoreB": 21},
        {"scoreA": 30, "scoreB": 25},
        {"scoreA": 30, "scoreB": 28}]}, 2)
    check patched == ptOk
    for index in 0 ..< before["matches"].len:
      let row = after["matches"][index]
      if row["id"].getStr() == target:
        check row["courts"][0].getStr() == "Court 1"
        check row["partai"][0]["scoreA"].getInt() == 30
      else:
        check row == before["matches"][index]

    check remove(database, communityId, id)

cleanup(database)
database.close()
