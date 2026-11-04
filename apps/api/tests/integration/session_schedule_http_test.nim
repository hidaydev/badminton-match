import std/[httpclient, json, options, os, strutils, unittest]
import mummy
import db/db
import sha256
import ../../src/app
import account/infrastructure/oidc
import account/infrastructure/session_store
import community/infrastructure/community_store
import player/store as playerStore
import platform/config/store
import share/crypto

const
  baseUrl = "http://127.0.0.1:18096"
  port = Port(18096)
  keysJson = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"""
  adminEmail = "sched-admin@example.com"
  hostEmail = "sched-host@example.com"
  memberEmail = "sched-member@example.com"

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
  communityId: string
  hostCookie, memberCookie: string
  players: seq[string]

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc call(verb: HttpMethod, path, cookie = "", body = "",
          ifMatch = ""): (int, string) =
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
  (response.code.int, response.body)

proc bootstrap() =
  database = openDb(dsn(), 1)
  discard database.execUpdate(
    """delete from session.games where community_id in
         (select id from platform.community where slug = 'sched-club')""")
  discard database.execUpdate(
    """delete from session.participants where community_id in
         (select id from platform.community where slug = 'sched-club')""")
  discard database.execUpdate(
    """delete from session.sessions where community_id in
         (select id from platform.community where slug = 'sched-club')""")
  discard database.execUpdate(
    """delete from player.claims where community_id in
         (select id from platform.community where slug = 'sched-club')""")
  discard database.execUpdate(
    """delete from player.players where community_id in
         (select id from platform.community where slug = 'sched-club')""")
  discard database.execUpdate(
    "delete from platform.community where slug = 'sched-club'")
  discard database.execUpdate(
    "delete from platform.user where google_sub like 'sched-%'")
  let ownerId = database.queryOne(
    """insert into platform.user (google_sub, email_hash, display_name, is_platform_owner)
       values ('sched-owner', $1, 'Owner', true) returning id""",
    @[textParam(sha256Hex("sched-owner@example.com"))]).get.get("id")
  communityId = community_store.create(database, "sched-club", "Schedule Club",
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
  discard member("sched-admin", adminEmail, "admin")
  hostCookie = createSession(database, member("sched-host", hostEmail, "host"), 30)
  memberCookie = createSession(database, member("sched-member", memberEmail, "member"),
    30)
  for name in ["Ani", "Budi", "Cakra", "Dewi"]:
    players.add(playerStore.create(database, communityId, name, "M", "").player["id"].getStr())

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
  doAssert up, "api did not start on port 18096"

bootstrap()

suite "session schedule HTTP":
  test "a host writes a schedule and reads the game back":
    let (created, body) = call(HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Wednesday","date":"2026-11-04"}""")
    check created == 201
    let sessionId = parseJson(body)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]}]}"""
    let (cannotWrite, _) = call(HttpPut,
      "/c/sched-club/sessions/" & sessionId & "/schedule", memberCookie,
      schedule, ifMatch = "\"1\"")
    check cannotWrite == 403
    let (written, writtenBody) = call(HttpPut,
      "/c/sched-club/sessions/" & sessionId & "/schedule", hostCookie,
      schedule, ifMatch = "\"1\"")
    check written == 200
    check parseJson(writtenBody)["version"].getInt() == 2
    let (game, gameBody) = call(HttpGet,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie)
    check game == 200
    let parsed = parseJson(gameBody)
    check parsed["sideA"].len == 2
    check parsed["sideA"][0].getStr() == players[0]
    check parsed["status"].getStr() == "scheduled"
    let (stale, _) = call(HttpPut,
      "/c/sched-club/sessions/" & sessionId & "/schedule", hostCookie,
      schedule, ifMatch = "\"1\"")
    check stale == 412
    let (noPrecondition, _) = call(HttpPut,
      "/c/sched-club/sessions/" & sessionId & "/schedule", hostCookie, schedule)
    check noPrecondition == 428

  test "scores, absence and skipping move the session version":
    let (_, body) = call(HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Scored","date":"2026-11-05"}""")
    let sessionId = parseJson(body)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]}]}"""
    discard call(HttpPut, "/c/sched-club/sessions/" & sessionId & "/schedule",
      hostCookie, schedule, ifMatch = "\"1\"")
    let (tie, _) = call(HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
      """{"scoreA":21,"scoreB":21}""", ifMatch = "\"2\"")
    check tie == 400
    let (scored, _) = call(HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
      """{"scoreA":21,"scoreB":15}""", ifMatch = "\"2\"")
    check scored == 200
    let (_, gameBody) = call(HttpGet,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie)
    check parseJson(gameBody)["status"].getStr() == "played"
    let (absent, _) = call(HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/absent", hostCookie,
      """{"playerIds":["""" & players[3] & """"]}""", ifMatch = "\"3\"")
    check absent == 200
    let (skipped, _) = call(HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0/skip", hostCookie,
      """{}""", ifMatch = "\"4\"")
    check skipped == 200
    let (_, afterBody) = call(HttpGet,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie)
    check parseJson(afterBody)["status"].getStr() == "cancelled"
    let (unknown, _) = call(HttpPut,
      "/c/sched-club/sessions/" & sessionId & "/schedule", hostCookie,
      """{"games":[{"round":1,"court":0,"sideA":["00000000-0000-0000-0000-000000000000"]}]}""",
      ifMatch = "\"5\"")
    check unknown == 400
