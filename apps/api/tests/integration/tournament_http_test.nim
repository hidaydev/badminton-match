## HTTP integration test for the six tournament operations on both formats.
## Skips without MAJADU_PG_DSN, like the other integration tests.

import std/[httpclient, json, options, os, strutils, unittest]
import mummy
import db/db
import sha256
import ../../src/app
import account/infrastructure/oidc
import account/infrastructure/session_store
import community/infrastructure/community_store
import platform/config/store
import share/crypto
import tournament/domain/classic
import tournament/domain/classic_draw
import tournament/domain/team
import tournament/domain/team_draw

const
  baseUrl = "http://127.0.0.1:18110"
  port = Port(18110)
  keysJson = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"""
  slug = "tour-http"
  otherSlug = "tour-http-other"
  adminEmail = "tour-admin@example.com"
  memberEmail = "tour-member@example.com"

type
  ServeArgs = object
    server: Server
    port: Port

  Reply = object
    status: int
    body: string
    location: string

proc serveThread(args: ServeArgs) {.thread.} =
  try:
    args.server.serve(args.port, "127.0.0.1")
  except MummyError:
    discard

var
  database: Db
  communityId, otherCommunityId, adminId: string
  adminCookie, memberCookie: string

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

proc classicSnapshot(): ClassicTournament =
  var pairs: seq[Pair] = @[]
  for index in 1 .. 16:
    pairs.add(Pair(id: "p" & $index,
      name: "Player " & $(index * 2 - 1) & " & Player " & $(index * 2)))
  generateTournament("HTTP Cup", "2026-11-11", pairs, 11)

proc teamSnapshot(): TeamTournament =
  var ids: seq[string] = @[]
  for index, name in TeamNames:
    var team = TeamInfo(id: "t" & $(index + 1), name: name)
    for offset, cls in TeamClasses:
      team.players.add(TeamPlayer(name: name & " P" & $(offset + 1), cls: cls))
    result.teams.add(team)
    ids.add(team.id)
  result.name = "HTTP Team Cup"
  result.date = "2026-11-12"
  result.matches = drawGroupMatches(ids)
  result.matches.add(finalMatch(ids[0], ids[1]))

proc call(verb: HttpMethod, path, cookie = "", body = "",
          ifMatch = ""): Reply =
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  var headers = newHttpHeaders()
  headers["Origin"] = "http://127.0.0.1:5173"
  if cookie.len > 0:
    headers["Cookie"] = "majadu_session=" & cookie
  if body.len > 0:
    headers["Content-Type"] = "application/json"
  if ifMatch.len > 0:
    headers["If-Match"] = ifMatch
  let response = client.request(baseUrl & path, httpMethod = verb,
    headers = headers, body = body)
  result.status = response.code.int
  result.body = response.body
  for key, value in response.headers.pairs:
    if key.toLowerAscii() == "location":
      result.location = value

proc cleanup(database: Db) =
  const statements = [
    """delete from rating.events where community_id in
         (select id from platform.community where slug in ($1, $2))""",
    """delete from rating.player_state where community_id in
         (select id from platform.community where slug in ($1, $2))""",
    """delete from rating.sources where community_id in
         (select id from platform.community where slug in ($1, $2))""",
    """delete from tournament.team_partai where community_id in
         (select id from platform.community where slug in ($1, $2))""",
    """delete from tournament.team_matches where community_id in
         (select id from platform.community where slug in ($1, $2))""",
    """delete from tournament.team_players where community_id in
         (select id from platform.community where slug in ($1, $2))""",
    """delete from tournament.teams where community_id in
         (select id from platform.community where slug in ($1, $2))""",
    """delete from tournament.groups where community_id in
         (select id from platform.community where slug in ($1, $2))""",
    """delete from tournament.matches where community_id in
         (select id from platform.community where slug in ($1, $2))""",
    """delete from tournament.pairs where community_id in
         (select id from platform.community where slug in ($1, $2))""",
    """delete from tournament.tournaments where community_id in
         (select id from platform.community where slug in ($1, $2))""",
    """delete from player.players where community_id in
         (select id from platform.community where slug in ($1, $2))""",
    "delete from platform.community where slug in ($1, $2)"]
  for statement in statements:
    discard database.execUpdate(statement,
      @[textParam(slug), textParam(otherSlug)])
  discard database.execUpdate(
    """delete from account.sessions where user_id in
         (select id from platform.user where google_sub like 'tour-%')""")
  discard database.execUpdate(
    "delete from platform.user where google_sub like 'tour-%'")

proc member(sub, email, role, community: string): string =
  let userId = database.queryOne(
    """insert into platform.user (google_sub, email_hash, display_name)
       values ($1, $2, $1) returning id""",
    @[textParam(sub), textParam(sha256Hex(email))]).get.get("id")
  discard database.execUpdate(
    """insert into community.membership (community_id, user_id, role)
       values ($1::uuid, $2::uuid, $3)""",
    @[textParam(community), textParam(userId), textParam(role)])
  userId

proc bootstrap() =
  database = openDb(getEnv("MAJADU_PG_DSN"), 1)
  cleanup(database)
  let ownerId = database.queryOne(
    """insert into platform.user (google_sub, email_hash, display_name,
         is_platform_owner)
       values ('tour-owner', $1, 'Owner', true) returning id""",
    @[textParam(sha256Hex("tour-owner@example.com"))]).get.get("id")
  communityId = communityStore.create(database, slug, "Tournament HTTP",
    adminEmail, "Asia/Jakarta", ownerId).communityId
  otherCommunityId = communityStore.create(database, otherSlug,
    "Tournament HTTP Other", adminEmail, "Asia/Jakarta", ownerId).communityId
  adminId = database.queryOne(
    """insert into platform.user (google_sub, email_hash, display_name)
       values ('tour-admin', $1, 'Admin') returning id""",
    @[textParam(sha256Hex(adminEmail))]).get.get("id")
  for community in [communityId, otherCommunityId]:
    discard database.execUpdate(
      """insert into community.membership (community_id, user_id, role)
         values ($1::uuid, $2::uuid, 'admin')""",
      @[textParam(community), textParam(adminId)])
  let memberId = member("tour-member", memberEmail, "member", communityId)
  adminCookie = createSession(database, adminId, 30)
  memberCookie = createSession(database, memberId, 30)
  install(newApp(database, OidcConfig(), loadKeyring(keysJson, "1"),
    newConfigCache(database)))
  let server = newServer(handler(), workerThreads = 4)
  var thread: Thread[ServeArgs]
  createThread(thread, serveThread, ServeArgs(server: server, port: port))
  var up = false
  for _ in 0 ..< 200:
    try:
      let client = newHttpClient(timeout = 1000)
      defer: client.close()
      if client.get(baseUrl & "/healthz").code.int == 200:
        up = true
        break
    except CatchableError:
      discard
    sleep(50)
  doAssert up, "api did not start on port 18110"

bootstrap()

suite "tournament HTTP":
  test "classic CRUD, OCC and single-match patch":
    let body = $classicJson(classicSnapshot())
    let denied = call(HttpPost, "/c/" & slug & "/tournaments", memberCookie, body)
    check denied.status == 403
    let created = call(HttpPost, "/c/" & slug & "/tournaments", adminCookie, body)
    check created.status == 201
    let createdBody = parseJson(created.body)
    let id = createdBody["id"].getStr()
    let path = "/c/" & slug & "/tournaments/" & id
    check createdBody["format"].getStr() == "classic"
    check createdBody["matches"].len == 32
    check created.location.contains(id)

    let got = call(HttpGet, path, memberCookie)
    check got.status == 200
    let current = parseJson(got.body)
    check current["matches"].len == 32
    check current["pairs"].len == 16
    let listed = call(HttpGet, "/c/" & slug & "/tournaments", memberCookie)
    check listed.status == 200
    check parseJson(listed.body)["items"].len == 1

    var changed = current
    changed["name"] = %"HTTP Cup Renamed"
    let noPrecondition = call(HttpPut, path, adminCookie, $changed)
    check noPrecondition.status == 428
    let put = call(HttpPut, path, adminCookie, $changed, ifMatch = "\"1\"")
    check put.status == 200
    check parseJson(put.body)["name"].getStr() == "HTTP Cup Renamed"
    let stale = call(HttpPut, path, adminCookie, $changed, ifMatch = "\"1\"")
    check stale.status == 412

    let target = current["matches"][0]["id"].getStr()
    let matchPath = path & "/matches/" & target
    let memberPatch = call(HttpPatch, matchPath, memberCookie,
      """{"scoreA":21,"scoreB":18}""", ifMatch = "\"2\"")
    check memberPatch.status == 403
    let patched = call(HttpPatch, matchPath, adminCookie,
      """{"scoreA":21,"scoreB":15}""", ifMatch = "\"2\"")
    check patched.status == 200
    let after = parseJson(patched.body)
    for index in 0 ..< current["matches"].len:
      let row = after["matches"][index]
      if row["id"].getStr() == target:
        check row["scoreA"].getInt() == 21
        check row["scoreB"].getInt() == 15
      else:
        check row == current["matches"][index]

    let foreign = call(HttpGet,
      "/c/" & otherSlug & "/tournaments/" & id, adminCookie)
    check foreign.status == 404
    let memberDelete = call(HttpDelete, path, memberCookie)
    check memberDelete.status == 403
    let deleted = call(HttpDelete, path, adminCookie)
    check deleted.status == 204
    check call(HttpGet, path, adminCookie).status == 404

  test "a draw with duplicate pair names is rejected":
    let snapshot = classicSnapshot()
    var data = snapshot
    data.pairs[1].name = data.pairs[0].name
    let created = call(HttpPost, "/c/" & slug & "/tournaments", adminCookie,
      $classicJson(data))
    check created.status == 400
    var kindsFound: seq[string] = @[]
    for issue in parseJson(created.body)["issues"]:
      kindsFound.add(issue["kind"].getStr())
    check "duplicate_pair_name" in kindsFound

  test "a match score needs both sides":
    let created = call(HttpPost, "/c/" & slug & "/tournaments", adminCookie,
      $classicJson(classicSnapshot()))
    check created.status == 201
    let snapshot = parseJson(created.body)
    let id = snapshot["id"].getStr()
    var emptyMatch = ""
    for match in snapshot["matches"]:
      if match["pairAId"].kind == JNull:
        emptyMatch = match["id"].getStr()
        break
    check emptyMatch.len > 0
    # The semifinal has no sides until its two quarterfinals are played, so a
    # score there would make a bye look like a result.
    let patched = call(HttpPatch,
      "/c/" & slug & "/tournaments/" & id & "/matches/" & emptyMatch,
      adminCookie, """{"scoreA":21,"scoreB":15}""", ifMatch = "\"1\"")
    check patched.status == 400
    let after = call(HttpGet, "/c/" & slug & "/tournaments/" & id,
      adminCookie)
    for match in parseJson(after.body)["matches"]:
      if match["id"].getStr() == emptyMatch:
        check match["scoreA"].kind == JNull
        check match["scoreB"].kind == JNull
    check call(HttpDelete, "/c/" & slug & "/tournaments/" & id,
      adminCookie).status == 204

  test "team create and get":
    let body = $teamJson(teamSnapshot())
    let created = call(HttpPost, "/c/" & slug & "/tournaments", adminCookie, body)
    check created.status == 201
    let createdBody = parseJson(created.body)
    let id = createdBody["id"].getStr()
    check createdBody["format"].getStr() == "team"
    check createdBody["teams"].len == 6
    let got = call(HttpGet, "/c/" & slug & "/tournaments/" & id, memberCookie)
    check got.status == 200
    let current = parseJson(got.body)
    check current["teams"].len == 6
    check current["teams"][0]["players"].len == 6
    check current["matches"].len == 10
    check current["matches"][0]["partai"].len == 3
    let foreign = call(HttpGet,
      "/c/" & otherSlug & "/tournaments/" & id, adminCookie)
    check foreign.status == 404
    check call(HttpDelete, "/c/" & slug & "/tournaments/" & id,
      adminCookie).status == 204

  test "rating a tournament needs the source sign-off":
    let body = $classicJson(classicSnapshot())
    let created = call(HttpPost, "/c/" & slug & "/tournaments", adminCookie, body)
    check created.status == 201
    let snapshot = parseJson(created.body)
    let id = snapshot["id"].getStr()
    let path = "/c/" & slug & "/tournaments/" & id
    let matchId = snapshot["matches"][0]["id"].getStr()
    let patched = call(HttpPatch, path & "/matches/" & matchId, adminCookie,
      """{"scoreA":30,"scoreB":20}""", ifMatch = "\"1\"")
    check patched.status == 200

    let refused = call(HttpPost, path & "/rating", adminCookie)
    check refused.status == 400
    check parseJson(refused.body)["code"].getStr() == "INVALID_STATE"

    let sourcePath = "/c/" & slug & "/rating-sources/" & id
    let signed = call(HttpPatch, sourcePath, adminCookie, """{"finalized":true}""")
    check signed.status == 200
    let ingested = call(HttpPost, path & "/rating", adminCookie)
    check ingested.status == 200
    check parseJson(ingested.body)["deltas"].getInt() > 0

    let blocked = call(HttpDelete, path & "/rating", adminCookie)
    check blocked.status == 403
    let unsigned = call(HttpPatch, sourcePath, adminCookie,
      """{"finalized":false}""")
    check unsigned.status == 200
    let reverted = call(HttpDelete, path & "/rating", adminCookie)
    check reverted.status == 204
    let events = database.queryOne(
      """select count(*)::int as total from rating.events
         where community_id = $1::uuid and source_id = $2::uuid""",
      @[textParam(communityId), textParam(id)])
    check events.get.get("total") == "0"
    # An id that names no tournament is a 404, not a 204 with a full rebuild.
    let missing = call(HttpDelete, "/c/" & slug &
      "/tournaments/00000000-0000-0000-0000-000000000000/rating", adminCookie)
    check missing.status == 404
    check parseJson(missing.body)["code"].getStr() == "NOT_FOUND"
    check call(HttpDelete, path, adminCookie).status == 204

  test "re-signing off a tournament replays the edited bracket":
    let body = $classicJson(classicSnapshot())
    let created = call(HttpPost, "/c/" & slug & "/tournaments", adminCookie, body)
    check created.status == 201
    let snapshot = parseJson(created.body)
    let id = snapshot["id"].getStr()
    let path = "/c/" & slug & "/tournaments/" & id
    let matchId = snapshot["matches"][0]["id"].getStr()
    check call(HttpPatch, path & "/matches/" & matchId, adminCookie,
      """{"scoreA":30,"scoreB":20}""", ifMatch = "\"1\"").status == 200
    let sourcePath = "/c/" & slug & "/rating-sources/" & id
    check call(HttpPatch, sourcePath, adminCookie,
      """{"finalized":true}""").status == 200
    check call(HttpPost, path & "/rating", adminCookie).status == 200
    let firstEvent = database.queryOne(
      """select id::text as id from rating.events
         where community_id = $1::uuid and source_id = $2::uuid""",
      @[textParam(communityId), textParam(id)]).get.get("id")
    let winsOf = proc(name: string): int =
      parseInt(database.queryOne(
        """select coalesce(s.wins, 0)::int as wins
           from player.players p
           left join rating.player_state s
             on s.community_id = p.community_id and s.player_id = p.id
           where p.community_id = $1::uuid and p.canonical_name = $2""",
        @[textParam(communityId), textParam(name)]).get.get("wins"))
    # The first match of the draw decides which pair names to watch, so the
    # assertion does not depend on the seed's group order.
    let firstPairOf = proc(pairId: string): string =
      for pair in snapshot["pairs"]:
        if pair["id"].getStr() == pairId:
          return pair["name"].getStr().split(" & ")[0]
      ""
    let sideAPlayer = firstPairOf(snapshot["matches"][0]["pairAId"].getStr())
    let sideBPlayer = firstPairOf(snapshot["matches"][0]["pairBId"].getStr())
    let aWins = winsOf(sideAPlayer)
    let bWins = winsOf(sideBPlayer)
    # Withdraw the sign-off, change the result, sign it off again.
    check call(HttpPatch, sourcePath, adminCookie,
      """{"finalized":false}""").status == 200
    check call(HttpPatch, path & "/matches/" & matchId, adminCookie,
      """{"scoreA":15,"scoreB":21}""", ifMatch = "\"2\"").status == 200
    check call(HttpPatch, sourcePath, adminCookie,
      """{"finalized":true}""").status == 200
    let events = database.query(
      """select id::text as id from rating.events
         where community_id = $1::uuid and source_id = $2::uuid""",
      @[textParam(communityId), textParam(id)])
    # The replay keeps the event id, so an admin page that already names the
    # source stays valid, while the counters below prove the new scores landed.
    check events.len == 1
    check events[0].get("id") == firstEvent
    # The replay reached the counters: the flipped result moves one win from the
    # first pair to the second.
    check winsOf(sideAPlayer) == aWins - 1
    check winsOf(sideBPlayer) == bWins + 1
    check call(HttpPatch, sourcePath, adminCookie,
      """{"finalized":false}""").status == 200
    check call(HttpDelete, path, adminCookie).status == 204

cleanup(database)
database.close()
