import std/[json, options, strutils, unittest]
import db/db
import community/infrastructure/community_store
import rating/infrastructure/ledger
import tests/fixtures
import ../http_support

const
  port = testPort(18092)
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  adminEmail = "player-admin@example.com"
  hostEmail = "player-host@example.com"
  memberEmail = "player-member@example.com"

var
  database: Db
  communityId, otherId: string
  adminCookie, hostCookie, memberCookie: string

proc bootstrap() =
  database = openDb(dsn(), 1)
  for slug in ["player-club", "player-other"]:
    purgeCommunity(database, slug)
  discard database.execUpdate(
    "delete from platform.user where google_sub like 'player-%'")
  let ownerId = newUser(database, "player-owner", "player-owner@example.com",
    "Owner", owner = true)
  communityId = community_store.create(database, "player-club", "Player Club",
    adminEmail, "Asia/Jakarta", ownerId).communityId
  otherId = community_store.create(database, "player-other", "Player Other",
    adminEmail, "Asia/Jakarta", ownerId).communityId
  let adminId = newUser(database, "player-admin", adminEmail, "player-admin")
  let hostId = newUser(database, "player-host", hostEmail, "player-host")
  let memberId = newUser(database, "player-member", memberEmail, "player-member")
  newMember(database, communityId, adminId, "admin")
  newMember(database, communityId, hostId, "host")
  newMember(database, communityId, memberId, "member")
  adminCookie = cookieFor(database, adminId)
  hostCookie = cookieFor(database, hostId)
  memberCookie = cookieFor(database, memberId)

  startServer(newTestApp(database), port, baseUrl)

bootstrap()

suite "player HTTP":
  test "members read, hosts write and only admins delete":
    let cannotCreate = call(baseUrl, HttpPost, "/c/player-club/players", memberCookie,
      """{"name":"Ani","gender":"F"}""")
    expectProblem(cannotCreate, 403)
    let created = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"  Ani   Lestari ","gender":"F","tier":"B+"}""")
    let body = created.body
    expectStatus(created, 201)
    let player = parseJson(body)
    check player["name"].getStr() == "Ani Lestari"
    check player["tier"].getStr() == "B+"
    let playerId = player["id"].getStr()
    let listed = call(baseUrl, HttpGet, "/c/player-club/players", memberCookie)
    let listBody = listed.body
    expectStatus(listed, 200)
    check parseJson(listBody)["items"].len == 1
    let cannotDelete = call(baseUrl, HttpDelete, "/c/player-club/players/" & playerId,
      hostCookie)
    expectProblem(cannotDelete, 403)
    let deleted = call(baseUrl, HttpDelete, "/c/player-club/players/" & playerId,
      adminCookie)
    expectStatus(deleted, 204)
    let gone = call(baseUrl, HttpGet, "/c/player-club/players/" & playerId, adminCookie)
    expectProblem(gone, 404)

  test "a duplicate name is a conflict, not a second row":
    let first = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Budi","gender":"M"}""")
    let firstBody = first.body
    expectStatus(first, 201)
    let firstId = parseJson(firstBody)["id"].getStr()
    let duplicate = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"budi","gender":"M"}""")
    expectProblem(duplicate, 409)
    # The 409 must be a refusal, not a second row: one 'budi' remains and it is
    # the row the first request created.
    let rows = database.query(
      """select id from player.players
         where community_id = $1::uuid and canonical_key = 'budi'""",
      @[textParam(communityId)])
    check rows.len == 1
    check rows[0].get("id") == firstId

  test "an invalid tier or gender is rejected":
    let badTier = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Cakra","tier":"Z"}""")
    expectProblem(badTier, 400)
    let badGender = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Cakra","gender":"X"}""")
    expectProblem(badGender, 400)
    let noName = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"   "}""")
    expectProblem(noName, 400)

  test "tier is sticky unless the patch sets or clears it":
    let body = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Dewi","gender":"F","tier":"A"}""").body
    let playerId = parseJson(body)["id"].getStr()
    let renamed = call(baseUrl, HttpPatch,
      "/c/player-club/players/" & playerId, hostCookie, """{"name":"Dewi S"}""")
    let renamedBody = renamed.body
    expectStatus(renamed, 200)
    check parseJson(renamedBody)["tier"].getStr() == "A"
    let cleared = call(baseUrl, HttpPatch,
      "/c/player-club/players/" & playerId, hostCookie, """{"tier":null}""")
    let clearedBody = cleared.body
    expectStatus(cleared, 200)
    check parseJson(clearedBody)["tier"].kind == JNull

  test "another community cannot see or mutate the player":
    let body = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Eka","gender":"F"}""").body
    let playerId = parseJson(body)["id"].getStr()
    let get = call(baseUrl, HttpGet, "/c/player-other/players/" & playerId, adminCookie)
    expectProblem(get, 404)
    let patch = call(baseUrl, HttpPatch, "/c/player-other/players/" & playerId,
      adminCookie, """{"name":"Stolen"}""")
    expectProblem(patch, 404)
    # The refused patch must not have reached the row: reading through the
    # owning community still shows the original name.
    let stored = database.queryOne(
      """select canonical_name from player.players
         where community_id = $1::uuid and id = $2::uuid""",
      @[textParam(communityId), textParam(playerId)]).get
    check stored.get("canonical_name") == "Eka"
    let delete = call(baseUrl, HttpDelete, "/c/player-other/players/" & playerId,
      adminCookie)
    expectProblem(delete, 404)
    # The refused delete left the row in place.
    check database.queryOne(
      """select count(*)::int as n from player.players
         where community_id = $1::uuid and id = $2::uuid""",
      @[textParam(communityId), textParam(playerId)]).get.get("n") == "1"

  test "a patch rejects a name that is not a string, blank or too long":
    let body = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Farah","gender":"F"}""").body
    let playerId = parseJson(body)["id"].getStr()
    for bad in ["""{"name":123}""", """{"name":"   "}""",
                """{"name":""" & "y".repeat(81) & """}"""]:
      let status = call(baseUrl, HttpPatch,
        "/c/player-club/players/" & playerId, hostCookie, bad)
      expectProblem(status, 400)
    let read = call(baseUrl, HttpGet, "/c/player-club/players/" & playerId,
      memberCookie)
    let after = read.body
    expectStatus(read, 200)
    check parseJson(after)["name"].getStr() == "Farah"

  test "achievements and claims answer 404 for a player of another community":
    let unknown = "11111111-1111-1111-1111-111111111111"
    for suffix in ["/achievements", "/claims"]:
      let status = call(baseUrl, HttpGet,
        "/c/player-club/players/" & unknown & suffix, memberCookie)
      expectProblem(status, 404)

  test "aliases are stored, replaced and returned":
    let created = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Fajar","gender":"M","aliases":["  Fajar  A ","Fajar"]}""")
    let body = created.body
    expectStatus(created, 201)
    let player = parseJson(body)
    check player["aliases"].len == 2
    let playerId = player["id"].getStr()
    let gotBody = call(baseUrl, HttpGet, "/c/player-club/players/" & playerId, memberCookie).body
    check parseJson(gotBody)["aliases"][0].getStr() == "Fajar"
    let patched = call(baseUrl, HttpPatch,
      "/c/player-club/players/" & playerId, hostCookie,
      """{"aliases":["Fajar","F A"]}""")
    let patchedBody = patched.body
    expectStatus(patched, 200)
    check parseJson(patchedBody)["aliases"].len == 2
    let emptied = call(baseUrl, HttpPatch,
      "/c/player-club/players/" & playerId, hostCookie, """{"aliases":[]}""")
    let emptiedBody = emptied.body
    expectStatus(emptied, 200)
    check parseJson(emptiedBody)["aliases"].len == 0

  test "an alias cannot point at two players":
    let body = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Gita","gender":"F","aliases":["Gita G"]}""").body
    let playerId = parseJson(body)["id"].getStr()
    let taken = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Gita Two","gender":"F","aliases":["gita g"]}""")
    expectProblem(taken, 409)
    let indraBody = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Indra","gender":"M","aliases":["Indra I"]}""").body
    check parseJson(indraBody)["aliases"][0].getStr() == "Indra I"
    let renameTaken = call(baseUrl, HttpPatch, "/c/player-club/players/" & playerId,
      hostCookie, """{"aliases":["Indra I"]}""")
    expectProblem(renameTaken, 409)
    let afterBody = call(baseUrl, HttpGet, "/c/player-club/players/" & playerId, memberCookie).body
    check parseJson(afterBody)["aliases"][0].getStr() == "Gita G"

  test "a blank or repeated alias is rejected":
    let blank = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Hana","aliases":["   "]}""")
    expectProblem(blank, 400)
    let repeated = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Hana Two","aliases":["Hana","hana"]}""")
    expectProblem(repeated, 400)
    let wrongType = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Hana Three","aliases":"hana"}""")
    expectProblem(wrongType, 400)

  test "an admin merges a duplicate into the target and moves its rows":
    let targetBody = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Iwan","gender":"M","aliases":["Iwan S"]}""").body
    let targetId = parseJson(targetBody)["id"].getStr()
    let sourceBody = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Iwan Setiawan","gender":"M","aliases":["Iwan Set","Iwan S2"]}""").body
    let sourceId = parseJson(sourceBody)["id"].getStr()
    # The merge moves the counters, so seed them through the ledger the way a
    # played game would: two games, one win, one loss.
    database.tx(proc(conn: DbConn) =
      addState(conn, communityId, @[sourceId], won = true)
      addState(conn, communityId, @[sourceId], won = false))

    let byHost = call(baseUrl, HttpPost, "/c/player-club/players/" & targetId & "/merge",
      hostCookie, """{"sourcePlayerId":"""" & sourceId & """"}""")
    expectProblem(byHost, 403)
    let byAdmin = call(baseUrl, HttpPost,
      "/c/player-club/players/" & targetId & "/merge", adminCookie,
      """{"sourcePlayerId":"""" & sourceId & """"}""")
    let merged = byAdmin.body
    expectStatus(byAdmin, 200)
    let result = parseJson(merged)
    check result["targetPlayerId"].getStr() == targetId
    check result["sourcePlayerId"].getStr() == sourceId
    check result["aliasesMoved"].getInt() == 2
    check result["ratingStateMoved"].getInt() == 1

    let gotBody = call(baseUrl, HttpGet, "/c/player-club/players/" & targetId, memberCookie).body
    let aliases = parseJson(gotBody)["aliases"]
    check aliases.len == 3
    let gone = call(baseUrl, HttpGet, "/c/player-club/players/" & sourceId, memberCookie)
    expectProblem(gone, 404)
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
    let body = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Joko","gender":"M"}""").body
    let playerId = parseJson(body)["id"].getStr()
    let same = call(baseUrl, HttpPost, "/c/player-club/players/" & playerId & "/merge",
      adminCookie, """{"sourcePlayerId":"""" & playerId & """"}""")
    expectProblem(same, 400)
    let unknown = call(baseUrl, HttpPost, "/c/player-club/players/" & playerId & "/merge",
      adminCookie, """{"sourcePlayerId":"00000000-0000-0000-0000-000000000000"}""")
    expectProblem(unknown, 404)
    let noBody = call(baseUrl, HttpPost, "/c/player-club/players/" & playerId & "/merge",
      adminCookie, """{}""")
    expectProblem(noBody, 400)

  test "members read a player's achievement shelf":
    let body = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Kiki","gender":"F"}""").body
    let playerId = parseJson(body)["id"].getStr()
    let status = call(baseUrl, HttpGet,
      "/c/player-club/players/" & playerId & "/achievements", memberCookie)
    let shelf = status.body
    expectStatus(status, 200)
    check parseJson(shelf)["items"].kind == JArray
    let missing = call(baseUrl, HttpGet,
      "/c/player-other/players/" & playerId & "/achievements", adminCookie)
    expectProblem(missing, 404)

  test "a plus in the player tier filter survives form decoding":
    discard call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Citra","gender":"F","tier":"B+"}""")
    discard call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Dodi","gender":"M","tier":"B"}""")
    let status = call(baseUrl, HttpGet, "/c/player-club/players?tier=B+",
      memberCookie)
    let body = status.body
    expectStatus(status, 200)
    let items = parseJson(body)["items"]
    check items.len == 1
    check items[0]["name"].getStr() == "Citra"
    # An unknown tier is ignored, not an empty page.
    let unfiltered = call(baseUrl, HttpGet, "/c/player-club/players?tier=Z",
      memberCookie).body
    check parseJson(unfiltered)["items"].len >= 2

  test "a failed audit insert rolls the player write back":
    # BE-02: the write and its evidence share one transaction. A trigger that
    # rejects the audit row must take the player with it, or the client would
    # see a 500 for a write that had already landed.
    discard database.execUpdate(
      """create or replace function t_player_audit_fail() returns trigger
         language plpgsql as $fn$
         begin
           if new.action = 'player.create' then
             raise exception 'injected audit failure' using errcode = 'P0001';
           end if;
           return new;
         end $fn$""")
    discard database.execUpdate(
      """create trigger t_player_audit_fail before insert on account.audit
         for each row execute function t_player_audit_fail()""")
    let failed = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Rolled Back","gender":"F"}""")
    expectStatus(failed, 500)
    discard database.execUpdate("drop trigger t_player_audit_fail on account.audit")
    discard database.execUpdate("drop function t_player_audit_fail()")
    check database.queryOne(
      """select id from player.players
         where community_id = $1::uuid and canonical_name = 'Rolled Back'""",
      @[textParam(communityId)]).isNone
    # The transaction rolled back cleanly, so the next create still works.
    let recovered = call(baseUrl, HttpPost, "/c/player-club/players", hostCookie,
      """{"name":"Rolled Back","gender":"F"}""")
    expectStatus(recovered, 201)

  test "a limit above the page cap returns the cap, not the request":
    # `pageParams` pulls the request down to `api.page_size_max` (500). Enough
    # rows make the cap observable without 500 HTTP writes.
    discard database.execUpdate(
      """insert into player.players (community_id, canonical_name, gender)
         select $1::uuid, 'Bulk Player ' || i, 'M'
         from generate_series(1, 520) as i""",
      @[textParam(communityId)])
    let status = call(baseUrl, HttpGet, "/c/player-club/players?limit=1000",
      memberCookie)
    let body = status.body
    expectStatus(status, 200)
    check parseJson(body)["items"].len == 500
    discard database.execUpdate(
      """delete from player.players
         where community_id = $1::uuid and canonical_name like 'Bulk Player %'""",
      @[textParam(communityId)])
