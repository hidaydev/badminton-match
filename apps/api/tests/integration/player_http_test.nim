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

const
  baseUrl = "http://127.0.0.1:18095"
  port = Port(18095)
  keysJson = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"""
  adminEmail = "player-admin@example.com"
  hostEmail = "player-host@example.com"
  memberEmail = "player-member@example.com"

type
  ServeArgs = object
    server: Server
    port: Port

proc serveThread(args: ServeArgs) {.thread.} =
  try:
    args.server.serve(args.port, "127.0.0.1")
  except MummyError:
    discard

var
  database: Db
  communityId, otherId: string
  adminCookie, hostCookie, memberCookie: string

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc call(verb: HttpMethod, path, cookie = "", body = ""): (int, string) =
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  var headers = newHttpHeaders()
  headers["Origin"] = "http://127.0.0.1:5173"
  if cookie.len > 0:
    headers["Cookie"] = "majadu_session=" & cookie
  if body.len > 0:
    headers["Content-Type"] = "application/json"
  let response = client.request(baseUrl & path, httpMethod = verb,
    headers = headers, body = body)
  (response.code.int, response.body)

proc bootstrap() =
  database = openDb(dsn(), 1)
  discard database.execUpdate(
    """delete from player.claims where community_id in
         (select id from platform.community
          where slug in ('player-club', 'player-other'))""")
  discard database.execUpdate(
    """delete from player.players where community_id in
         (select id from platform.community
          where slug in ('player-club', 'player-other'))""")
  discard database.execUpdate(
    "delete from platform.community where slug in ('player-club', 'player-other')")
  discard database.execUpdate(
    "delete from platform.user where google_sub like 'player-%'")
  let ownerId = database.queryOne(
    """insert into platform.user (google_sub, email_hash, display_name, is_platform_owner)
       values ('player-owner', $1, 'Owner', true) returning id""",
    @[textParam(sha256Hex("player-owner@example.com"))]).get.get("id")
  communityId = community_store.create(database, "player-club", "Player Club",
    adminEmail, "Asia/Jakarta", ownerId).communityId
  otherId = community_store.create(database, "player-other", "Player Other",
    adminEmail, "Asia/Jakarta", ownerId).communityId
  proc member(sub, email, role: string): string =
    let id = database.queryOne(
      """insert into platform.user (google_sub, email_hash, display_name)
         values ($1, $2, $1) returning id""",
      @[textParam(sub), textParam(sha256Hex(email))]).get.get("id")
    discard database.execUpdate(
      """insert into community.membership (community_id, user_id, role)
         values ($1::uuid, $2::uuid, $3)""",
      @[textParam(communityId), textParam(id), textParam(role)])
    id
  let adminId = member("player-admin", adminEmail, "admin")
  let hostId = member("player-host", hostEmail, "host")
  let memberId = member("player-member", memberEmail, "member")
  adminCookie = createSession(database, adminId, 30)
  hostCookie = createSession(database, hostId, 30)
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
  doAssert up, "api did not start on port 18095"

bootstrap()

suite "player HTTP":
  test "members read, hosts write and only admins delete":
    let (cannotCreate, _) = call(HttpPost, "/c/player-club/players", memberCookie,
      """{"name":"Ani","gender":"F"}""")
    check cannotCreate == 403
    let (created, body) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"  Ani   Lestari ","gender":"F","tier":"B+"}""")
    check created == 201
    let player = parseJson(body)
    check player["name"].getStr() == "Ani Lestari"
    check player["tier"].getStr() == "B+"
    let playerId = player["id"].getStr()
    let (listed, listBody) = call(HttpGet, "/c/player-club/players", memberCookie)
    check listed == 200
    check parseJson(listBody)["items"].len == 1
    let (cannotDelete, _) = call(HttpDelete, "/c/player-club/players/" & playerId,
      hostCookie)
    check cannotDelete == 403
    let (deleted, _) = call(HttpDelete, "/c/player-club/players/" & playerId,
      adminCookie)
    check deleted == 204
    let (gone, _) = call(HttpGet, "/c/player-club/players/" & playerId, adminCookie)
    check gone == 404

  test "a duplicate name is a conflict, not a second row":
    let (first, _) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Budi","gender":"M"}""")
    check first == 201
    let (duplicate, _) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"budi","gender":"M"}""")
    check duplicate == 409

  test "an invalid tier or gender is rejected":
    let (badTier, _) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Cakra","tier":"Z"}""")
    check badTier == 400
    let (badGender, _) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Cakra","gender":"X"}""")
    check badGender == 400
    let (noName, _) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"   "}""")
    check noName == 400

  test "tier is sticky unless the patch sets or clears it":
    let (_, body) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Dewi","gender":"F","tier":"A"}""")
    let playerId = parseJson(body)["id"].getStr()
    let (renamed, renamedBody) = call(HttpPatch,
      "/c/player-club/players/" & playerId, hostCookie, """{"name":"Dewi S"}""")
    check renamed == 200
    check parseJson(renamedBody)["tier"].getStr() == "A"
    let (cleared, clearedBody) = call(HttpPatch,
      "/c/player-club/players/" & playerId, hostCookie, """{"tier":null}""")
    check cleared == 200
    check parseJson(clearedBody)["tier"].kind == JNull

  test "another community cannot see or mutate the player":
    let (_, body) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Eka","gender":"F"}""")
    let playerId = parseJson(body)["id"].getStr()
    let (get, _) = call(HttpGet, "/c/player-other/players/" & playerId, adminCookie)
    check get == 404
    let (patch, _) = call(HttpPatch, "/c/player-other/players/" & playerId,
      adminCookie, """{"name":"Stolen"}""")
    check patch == 404
    let (delete, _) = call(HttpDelete, "/c/player-other/players/" & playerId,
      adminCookie)
    check delete == 404

  test "a patch rejects a name that is not a string, blank or too long":
    let (_, body) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Farah","gender":"F"}""")
    let playerId = parseJson(body)["id"].getStr()
    for bad in ["""{"name":123}""", """{"name":"   "}""",
                """{"name":""" & "y".repeat(81) & """}"""]:
      let (status, _) = call(HttpPatch,
        "/c/player-club/players/" & playerId, hostCookie, bad)
      check status == 400
    let (read, after) = call(HttpGet, "/c/player-club/players/" & playerId,
      memberCookie)
    check read == 200
    check parseJson(after)["name"].getStr() == "Farah"

  test "achievements and claims answer 404 for a player of another community":
    let unknown = "11111111-1111-1111-1111-111111111111"
    for suffix in ["/achievements", "/claims"]:
      let (status, _) = call(HttpGet,
        "/c/player-club/players/" & unknown & suffix, memberCookie)
      check status == 404

  test "aliases are stored, replaced and returned":
    let (created, body) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Fajar","gender":"M","aliases":["  Fajar  A ","Fajar"]}""")
    check created == 201
    let player = parseJson(body)
    check player["aliases"].len == 2
    let playerId = player["id"].getStr()
    let (_, gotBody) = call(HttpGet, "/c/player-club/players/" & playerId, memberCookie)
    check parseJson(gotBody)["aliases"][0].getStr() == "Fajar"
    let (patched, patchedBody) = call(HttpPatch,
      "/c/player-club/players/" & playerId, hostCookie,
      """{"aliases":["Fajar","F A"]}""")
    check patched == 200
    check parseJson(patchedBody)["aliases"].len == 2
    let (emptied, emptiedBody) = call(HttpPatch,
      "/c/player-club/players/" & playerId, hostCookie, """{"aliases":[]}""")
    check emptied == 200
    check parseJson(emptiedBody)["aliases"].len == 0

  test "an alias cannot point at two players":
    let (_, body) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Gita","gender":"F","aliases":["Gita G"]}""")
    let playerId = parseJson(body)["id"].getStr()
    let (taken, _) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Gita Two","gender":"F","aliases":["gita g"]}""")
    check taken == 409
    let (_, indraBody) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Indra","gender":"M","aliases":["Indra I"]}""")
    check parseJson(indraBody)["aliases"][0].getStr() == "Indra I"
    let (renameTaken, _) = call(HttpPatch, "/c/player-club/players/" & playerId,
      hostCookie, """{"aliases":["Indra I"]}""")
    check renameTaken == 409
    let (_, afterBody) = call(HttpGet, "/c/player-club/players/" & playerId, memberCookie)
    check parseJson(afterBody)["aliases"][0].getStr() == "Gita G"

  test "a blank or repeated alias is rejected":
    let (blank, _) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Hana","aliases":["   "]}""")
    check blank == 400
    let (repeated, _) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Hana Two","aliases":["Hana","hana"]}""")
    check repeated == 400
    let (wrongType, _) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Hana Three","aliases":"hana"}""")
    check wrongType == 400

  test "an admin merges a duplicate into the target and moves its rows":
    let (_, targetBody) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Iwan","gender":"M","aliases":["Iwan S"]}""")
    let targetId = parseJson(targetBody)["id"].getStr()
    let (_, sourceBody) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Iwan Setiawan","gender":"M","aliases":["Iwan Set","Iwan S2"]}""")
    let sourceId = parseJson(sourceBody)["id"].getStr()
    discard database.execUpdate(
      """insert into rating.player_state
           (community_id, player_id, games_played, wins, losses)
         values ($1::uuid, $2::uuid, 2, 1, 1)""",
      @[textParam(communityId), textParam(sourceId)])

    let (byHost, _) = call(HttpPost, "/c/player-club/players/" & targetId & "/merge",
      hostCookie, """{"sourcePlayerId":"""" & sourceId & """"}""")
    check byHost == 403
    let (byAdmin, merged) = call(HttpPost,
      "/c/player-club/players/" & targetId & "/merge", adminCookie,
      """{"sourcePlayerId":"""" & sourceId & """"}""")
    check byAdmin == 200
    let result = parseJson(merged)
    check result["targetPlayerId"].getStr() == targetId
    check result["sourcePlayerId"].getStr() == sourceId
    check result["aliasesMoved"].getInt() == 2
    check result["ratingStateMoved"].getInt() == 1

    let (_, gotBody) = call(HttpGet, "/c/player-club/players/" & targetId, memberCookie)
    let aliases = parseJson(gotBody)["aliases"]
    check aliases.len == 3
    let (gone, _) = call(HttpGet, "/c/player-club/players/" & sourceId, memberCookie)
    check gone == 404
    let logged = database.queryOne(
      """select source_id, target_id, rows_moved from player.merge_log
         where community_id = $1::uuid order by created_at desc limit 1""",
      @[textParam(communityId)])
    check logged.isSome
    check logged.get.get("source_id") == sourceId
    check logged.get.get("target_id") == targetId
    check logged.get.get("rows_moved") == "3"
    let audited = database.queryOne(
      """select count(*)::int as n from account.audit
         where community_id = $1::uuid and action = 'player.merge'""",
      @[textParam(communityId)])
    check audited.get.get("n") == "1"

  test "merging the same player or an unknown player fails":
    let (_, body) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Joko","gender":"M"}""")
    let playerId = parseJson(body)["id"].getStr()
    let (same, _) = call(HttpPost, "/c/player-club/players/" & playerId & "/merge",
      adminCookie, """{"sourcePlayerId":"""" & playerId & """"}""")
    check same == 400
    let (unknown, _) = call(HttpPost, "/c/player-club/players/" & playerId & "/merge",
      adminCookie, """{"sourcePlayerId":"00000000-0000-0000-0000-000000000000"}""")
    check unknown == 404
    let (noBody, _) = call(HttpPost, "/c/player-club/players/" & playerId & "/merge",
      adminCookie, """{}""")
    check noBody == 400

  test "members read a player's achievement shelf":
    let (_, body) = call(HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Kiki","gender":"F"}""")
    let playerId = parseJson(body)["id"].getStr()
    let (status, shelf) = call(HttpGet,
      "/c/player-club/players/" & playerId & "/achievements", memberCookie)
    check status == 200
    check parseJson(shelf)["items"].kind == JArray
    let (missing, _) = call(HttpGet,
      "/c/player-other/players/" & playerId & "/achievements", adminCookie)
    check missing == 404
