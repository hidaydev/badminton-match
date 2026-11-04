import std/[httpclient, json, options, os, strutils, unittest]
import mummy
import db/db
import sha256
import ../../src/app
import account/infrastructure/oidc
import account/infrastructure/session_store
import community/infrastructure/community_store
import platform/config/store
import player/store as playerStore
import share/crypto
import share/store as shareStore

const
  baseUrl = "http://127.0.0.1:18098"
  port = Port(18098)
  keysJson = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"""

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
  keyring: Keyring
  communityId, sessionId: string
  memberCookie: string
  players: seq[string]

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc send(verb: HttpMethod, path, cookie = "", body = ""): (int, string) =
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  var headers = newHttpHeaders()
  if cookie.len > 0:
    headers["Cookie"] = "majadu_session=" & cookie
  if verb in {HttpPost, HttpPatch, HttpPut, HttpDelete}:
    headers["Origin"] = "http://127.0.0.1:5173"
  if body.len > 0:
    headers["Content-Type"] = "application/json"
  let response = client.request(baseUrl & path, httpMethod = verb,
    headers = headers, body = body)
  (response.code.int, response.body)

proc call(path, cookie = ""): (int, string) = send(HttpGet, path, cookie)

proc bootstrap() =
  database = openDb(dsn(), 1)
  keyring = loadKeyring(keysJson, "1")
  for statement in [
    """delete from rating.deltas where community_id in
         (select id from platform.community where slug = 'rank-club')""",
    """delete from rating.events where community_id in
         (select id from platform.community where slug = 'rank-club')""",
    """delete from rating.player_state where community_id in
         (select id from platform.community where slug = 'rank-club')""",
    """delete from rating.sources where community_id in
         (select id from platform.community where slug = 'rank-club')""",
    """delete from session.links where community_id in
         (select id from platform.community where slug = 'rank-club')""",
    """delete from session.sessions where community_id in
         (select id from platform.community where slug = 'rank-club')""",
    """delete from player.players where community_id in
         (select id from platform.community where slug = 'rank-club')""",
    "delete from platform.community where slug = 'rank-club'",
    "delete from platform.user where google_sub like 'rank-%'"]:
    discard database.execUpdate(statement)
  let ownerId = database.queryOne(
    """insert into platform.user (google_sub, email_hash, display_name, is_platform_owner)
       values ('rank-owner', $1, 'Owner', true) returning id""",
    @[textParam(sha256Hex("rank-owner@example.com"))]).get.get("id")
  communityId = community_store.create(database, "rank-club", "Rank Club",
    "rank-admin@example.com", "Asia/Jakarta", ownerId).communityId
  let memberId = database.queryOne(
    """insert into platform.user (google_sub, email_hash, display_name)
       values ('rank-member', $1, 'Member') returning id""",
    @[textParam(sha256Hex("rank-member@example.com"))]).get.get("id")
  discard database.execUpdate(
    """insert into community.membership (community_id, user_id, role)
       values ($1::uuid, $2::uuid, 'member')""",
    @[textParam(communityId), textParam(memberId)])
  memberCookie = createSession(database, memberId, 30)
  for name in ["Ani", "Budi", "Cakra"]:
    players.add(playerStore.create(database, communityId, name, "M", "").player["id"].getStr())
  sessionId = database.queryOne(
    """insert into session.sessions
         (community_id, title, session_date, status, source, approved_at)
       values ($1::uuid, 'Rank night', current_date, 'locked', 'manual', now())
       returning id""", @[textParam(communityId)]).get.get("id")
  let eventId = database.queryOne(
    """insert into rating.events (community_id, local_date, event_type, source_id)
       values ($1::uuid, current_date, 'session', $2::uuid) returning id""",
    @[textParam(communityId), textParam(sessionId)]).get.get("id")
  let points = [900, 600, 300]
  for index, player in players:
    discard database.execUpdate(
      """insert into rating.deltas (community_id, event_id, side, player_id, delta)
         values ($1::uuid, $2::uuid, $3, $4::uuid, $5)""",
      @[textParam(communityId), textParam(eventId),
        textParam(if index mod 2 == 0: "a" else: "b"), textParam(player),
        intParam(points[index].int64)])
  for player in players:
    discard database.execUpdate(
      """insert into rating.player_state
           (community_id, player_id, rating, games_played, wins, losses)
       values ($1::uuid, $2::uuid, 0, 4, 2, 2)""",
      @[textParam(communityId), textParam(player)])
  install(newApp(database, OidcConfig(), keyring, newConfigCache(database)))
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
  doAssert up, "api did not start on port 18098"

bootstrap()

suite "rankings HTTP":
  test "members read an ordered board and a player row":
    let (status, body) = call("/c/rank-club/rankings", memberCookie)
    check status == 200
    let items = parseJson(body)["items"]
    check items.len == 3
    check items[0]["playerId"].getStr() == players[0]
    check items[0]["rank"].getInt() == 1
    check items[0]["points"].getInt() > items[1]["points"].getInt()
    let (detail, detailBody) = call(
      "/c/rank-club/rankings/" & players[1], memberCookie)
    check detail == 200
    check parseJson(detailBody)["rank"].getInt() == 2

  test "the tier filter is applied by the server":
    let (status, body) = call("/c/rank-club/rankings?tier=B", memberCookie)
    check status == 200
    let items = parseJson(body)["items"]
    check items.len == 0
    discard database.execUpdate(
      """update player.players set tier = 'B' where id = $1::uuid""",
      @[textParam(players[0])])
    let (filteredStatus, filteredBody) = call("/c/rank-club/rankings?tier=B",
      memberCookie)
    check filteredStatus == 200
    let filtered = parseJson(filteredBody)["items"]
    check filtered.len == 1
    check filtered[0]["playerId"].getStr() == players[0]

  test "an unknown player or a non-member gets 404":
    let (missing, _) = call("/c/rank-club/rankings/00000000-0000-0000-0000-000000000000",
      memberCookie)
    check missing == 404
    let (foreign, _) = call("/c/rank-club/rankings")
    check foreign == 401

  test "stats come from player_state":
    let (status, body) = call("/c/rank-club/players/" & players[0] & "/stats",
      memberCookie)
    check status == 200
    let stats = parseJson(body)
    check stats["name"].getStr() == "Ani"
    check stats["games"].getInt() == 4
    check stats["wins"].getInt() == 2

  test "the public board resolves through a share code":
    let ownerId = database.queryOne(
      """select id from platform.user where google_sub = 'rank-owner'"""
      ).get.get("id")
    let code = shareStore.issue(database, keyring, communityId, sessionId, ownerId)
    let (status, body) = call("/s/" & code & "/rankings")
    check status == 200
    check parseJson(body)["items"].len == 3
    let (unknown, _) = call("/s/nope/rankings")
    check unknown == 404

  test "the public player detail resolves through the same share code":
    let ownerId = database.queryOne(
      """select id from platform.user where google_sub = 'rank-owner'"""
      ).get.get("id")
    let code = shareStore.issue(database, keyring, communityId, sessionId, ownerId)
    let (status, body) = call("/s/" & code & "/rankings/" & players[0])
    check status == 200
    check parseJson(body)["rank"].getInt() == 1
    check parseJson(body)["playerId"].getStr() == players[0]
    let (missing, _) = call("/s/" & code &
      "/rankings/00000000-0000-0000-0000-000000000000")
    check missing == 404
    let (unknown, _) = call("/s/nope/rankings/" & players[0])
    check unknown == 404

  test "revoking the share link kills the public code":
    let ownerId = database.queryOne(
      """select id from platform.user where google_sub = 'rank-owner'"""
      ).get.get("id")
    let adminId = database.queryOne(
      """insert into platform.user (google_sub, email_hash, display_name)
         values ('rank-admin', $1, 'Rank Admin') returning id""",
      @[textParam(sha256Hex("rank-admin@example.com"))]).get.get("id")
    discard database.execUpdate(
      """insert into community.membership (community_id, user_id, role)
         values ($1::uuid, $2::uuid, 'admin')""",
      @[textParam(communityId), textParam(adminId)])
    let adminCookie = createSession(database, adminId, 30)
    let code = shareStore.issue(database, keyring, communityId, sessionId, ownerId)
    let (live, _) = call("/s/" & code)
    check live == 200
    let path = "/c/rank-club/sessions/" & sessionId & "/share"
    let (revoked, _) = send(HttpDelete, path, adminCookie)
    check revoked == 204
    let (gone, _) = call("/s/" & code)
    check gone == 404
    let (again, _) = send(HttpDelete, path, adminCookie)
    check again == 404

  test "finalizing a rating source protects it from a revert":
    let adminId = database.queryOne(
      """select user_id from community.membership m
         join platform.user u on u.id = m.user_id
         where u.google_sub = 'rank-admin' limit 1""").get.get("user_id")
    let adminCookie = createSession(database, adminId, 30)
    let eventId = database.queryOne(
      """select id from rating.events
         where community_id = $1::uuid and source_id = $2::uuid""",
      @[textParam(communityId), textParam(sessionId)]).get.get("id")
    let path = "/c/rank-club/rating-sources/" & eventId
    let (asMember, _) = call(path, memberCookie)
    check asMember == 403
    let (badBody, _) = send(HttpPatch, path, adminCookie,
      """{"finalized":"yes"}""")
    check badBody == 400
    let (missing, _) = send(HttpPatch,
      "/c/rank-club/rating-sources/00000000-0000-0000-0000-000000000000",
      adminCookie, """{"finalized":true}""")
    check missing == 404
    let (finalized, finalizedBody) = send(HttpPatch, path, adminCookie,
      """{"finalized":true}""")
    check finalized == 200
    check parseJson(finalizedBody)["finalized"].getBool()
    let (refused, _) = send(HttpDelete,
      "/c/rank-club/sessions/" & sessionId & "/rating", adminCookie)
    check refused == 403
    let (unfinalized, unfinalizedBody) = send(HttpPatch, path, adminCookie,
      """{"finalized":false}""")
    check unfinalized == 200
    check not parseJson(unfinalizedBody)["finalized"].getBool()
    let (reverted, _) = send(HttpDelete,
      "/c/rank-club/sessions/" & sessionId & "/rating", adminCookie)
    check reverted == 200
