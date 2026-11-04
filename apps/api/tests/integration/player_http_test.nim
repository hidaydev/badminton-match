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
