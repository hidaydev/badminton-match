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
  hostCookie, adminCookie, memberCookie: string
  players: seq[string]

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc call(verb: HttpMethod, path, cookie = "", body = "",
          ifMatch = "", ifNoneMatch = "", apiVersion = "",
          idempotencyKey = ""): (int, string) =
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
  if ifNoneMatch.len > 0:
    headers["If-None-Match"] = ifNoneMatch
  if apiVersion.len > 0:
    headers["X-API-Version"] = apiVersion
  if idempotencyKey.len > 0:
    headers["Idempotency-Key"] = idempotencyKey
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
    """delete from platform.idempotency_keys where user_id in
         (select id from platform.user where google_sub like 'sched-%')""")
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
  adminCookie = createSession(database,
    member("sched-admin", adminEmail, "admin"), 30)
  hostCookie = createSession(database, member("sched-host", hostEmail, "host"), 30)
  memberCookie = createSession(database, member("sched-member", memberEmail, "member"),
    30)
  for name in ["Ani", "Budi", "Cakra", "Dewi", "Eka", "Fajar", "Gita", "Hadi"]:
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
    # The detail read carries the schedule, because there is no read endpoint
    # for the schedule itself and a page cannot guess the game keys.
    let (detail, detailBody) = call(HttpGet,
      "/c/sched-club/sessions/" & sessionId, hostCookie)
    check detail == 200
    let session = parseJson(detailBody)
    check session["version"].getInt() == 2
    check session["startTime"].getStr() == "00:00"
    check session["slotMinutes"].getInt() == 30
    check session["games"].len == 1
    check session["games"][0]["sideA"].len == 2
    check session["games"][0]["court"].getInt() == 0
    check session["participants"].len == 4
    check session["participants"][0]["name"].getStr() == "Ani"
    # A poll that already holds this version is a 304 without the body; a
    # stale validator still gets the full read.
    let etag = "\"" & $session["version"].getInt() & "\""
    let (notModified, notModifiedBody) = call(HttpGet,
      "/c/sched-club/sessions/" & sessionId, hostCookie, ifNoneMatch = etag)
    check notModified == 304
    check notModifiedBody.len == 0
    let (staleEtag, _) = call(HttpGet,
      "/c/sched-club/sessions/" & sessionId, hostCookie, ifNoneMatch = "\"1\"")
    check staleEtag == 200
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

  test "a per-player skip keeps the game and reports the skipped players":
    let (_, body) = call(HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Partial skip","date":"2026-11-08"}""")
    let sessionId = parseJson(body)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]}]}"""
    discard call(HttpPut, "/c/sched-club/sessions/" & sessionId & "/schedule",
      hostCookie, schedule, ifMatch = "\"1\"")
    let (skipped, _) = call(HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0/skip", hostCookie,
      """{"playerIds":["""" & players[0] & """"]}""", ifMatch = "\"2\"")
    check skipped == 200
    let (_, detailBody) = call(HttpGet,
      "/c/sched-club/sessions/" & sessionId, hostCookie)
    let detail = parseJson(detailBody)
    check detail["version"].getInt() == 3
    check detail["games"][0]["status"].getStr() == "scheduled"
    check detail["skippedPlayers"]["0-0"][0].getStr() == players[0]

    let (cleared, _) = call(HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0/skip", hostCookie,
      """{"playerIds":[]}""", ifMatch = "\"3\"")
    check cleared == 200
    let (_, afterBody) = call(HttpGet,
      "/c/sched-club/sessions/" & sessionId, hostCookie)
    check parseJson(afterBody)["skippedPlayers"].len == 0

  test "deleting a session is host-for-draft and admin-for-any":
    let (created, body) = call(HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Draft to delete","date":"2026-11-06"}""")
    check created == 201
    let draftId = parseJson(body)["id"].getStr()
    let (denied, _) = call(HttpDelete,
      "/c/sched-club/sessions/" & draftId, memberCookie)
    check denied == 403
    let (deleted, _) = call(HttpDelete,
      "/c/sched-club/sessions/" & draftId, hostCookie)
    check deleted == 204
    let (gone, _) = call(HttpGet,
      "/c/sched-club/sessions/" & draftId, hostCookie)
    check gone == 404

    let (_, lockedBody) = call(HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Locked to delete","date":"2026-11-07"}""")
    let lockedId = parseJson(lockedBody)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]}]}"""
    discard call(HttpPut, "/c/sched-club/sessions/" & lockedId & "/schedule",
      hostCookie, schedule, ifMatch = "\"1\"")
    discard database.execUpdate(
      """update session.sessions set status = 'locked' where id = $1::uuid""",
      @[textParam(lockedId)])
    let (hostRefused, _) = call(HttpDelete,
      "/c/sched-club/sessions/" & lockedId, hostCookie)
    check hostRefused == 403
    let (adminDeleted, _) = call(HttpDelete,
      "/c/sched-club/sessions/" & lockedId, adminCookie)
    check adminDeleted == 204
    let games = database.queryOne(
      """select count(*)::int as n from session.games where session_id = $1::uuid""",
      @[textParam(lockedId)])
    check games.get.get("n") == "0"
    let (missing, _) = call(HttpDelete,
      "/c/sched-club/sessions/" & lockedId, adminCookie)
    check missing == 404

  test "a swap exchanges players across games and bumps the version":
    let (_, created) = call(HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Swap night","date":"2026-11-08"}""")
    let sessionId = parseJson(created)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]},
      {"round":0,"court":1,"sideA":["""" & players[4] & """","""" &
      players[5] & """"],"sideB":["""" & players[6] & """","""" &
      players[7] & """"]}]}"""
    let (written, _) = call(HttpPut,
      "/c/sched-club/sessions/" & sessionId & "/schedule", hostCookie, schedule,
      ifMatch = "\"1\"")
    check written == 200
    let swapBody = """{"type":"player","a":{"slot":0,"court":0,"team":"A","position":0},"b":{"slot":0,"court":1,"team":"A","position":0}}"""
    let path = "/c/sched-club/sessions/" & sessionId & "/swap"
    let (noPrecondition, _) = call(HttpPost, path, hostCookie, swapBody)
    check noPrecondition == 428
    let (invalid, _) = call(HttpPost, path, hostCookie, """{"type":"nope"}""",
      ifMatch = "\"2\"")
    check invalid == 400
    let (swapped, swappedBody) = call(HttpPost, path, hostCookie, swapBody,
      ifMatch = "\"2\"")
    check swapped == 200
    check parseJson(swappedBody)["version"].getInt() == 3
    let (_, firstGame) = call(HttpGet,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie)
    check parseJson(firstGame)["sideA"][0].getStr() == players[4]
    let (_, secondGame) = call(HttpGet,
      "/c/sched-club/sessions/" & sessionId & "/games/0-1", hostCookie)
    check parseJson(secondGame)["sideA"][0].getStr() == players[0]
    let (stale, _) = call(HttpPost, path, hostCookie, swapBody,
      ifMatch = "\"2\"")
    check stale == 412
    let (memberDenied, _) = call(HttpPost, path, memberCookie, swapBody,
      ifMatch = "\"3\"")
    check memberDenied == 403
    discard database.execUpdate(
      """update session.sessions set status = 'locked' where id = $1::uuid""",
      @[textParam(sessionId)])
    let (locked, _) = call(HttpPost, path, hostCookie, swapBody,
      ifMatch = "\"3\"")
    check locked == 403

  test "creating a session rejects invalid input with a 400":
    let path = "/c/sched-club/sessions"
    let (missingDate, _) = call(HttpPost, path, hostCookie, """{"title":"x"}""")
    check missingDate == 400
    let (badDate, _) = call(HttpPost, path, hostCookie,
      """{"date":"2026-02-30"}""")
    check badDate == 400
    let (badTime, _) = call(HttpPost, path, hostCookie,
      """{"date":"2026-11-04","startTime":"9:00"}""")
    check badTime == 400
    let (badSlot, _) = call(HttpPost, path, hostCookie,
      """{"date":"2026-11-04","slotMinutes":0}""")
    check badSlot == 400
    let (tooBig, _) = call(HttpPost, path, hostCookie,
      """{"date":"2026-11-04","slotMinutes":241}""")
    check tooBig == 400
    let (badJson, _) = call(HttpPost, path, hostCookie, "{")
    check badJson == 400
    let (wrongType, _) = call(HttpPost, path, hostCookie,
      """{"date":20261104}""")
    check wrongType == 400
    # A title is required now: a blank one used to create a nameless draft.
    let (noTitle, _) = call(HttpPost, path, hostCookie,
      """{"date":"2026-11-04"}""")
    check noTitle == 400
    let (blankTitle, _) = call(HttpPost, path, hostCookie,
      """{"title":"   ","date":"2026-11-04"}""")
    check blankTitle == 400
    let (longTitle, _) = call(HttpPost, path, hostCookie,
      """{"title":"""" & "x".repeat(121) &
      """","date":"2026-11-04"}""")
    check longTitle == 400
    let (created, body) = call(HttpPost, path, hostCookie,
      """{"title":"Valid","date":"2026-11-04","startTime":"19:30","slotMinutes":45}""")
    check created == 201
    check parseJson(body)["date"].getStr() == "2026-11-04"

  test "a malformed id is a 400 and never reaches the database":
    # The route casts every id to uuid; PostgreSQL's 22P02 used to surface as a
    # 500, which hid a caller mistake behind an internal error.
    for path in ["/c/sched-club/sessions/not-a-uuid",
                 "/c/sched-club/sessions/not-a-uuid/standings",
                 "/c/sched-club/tournaments/not-a-uuid"]:
      let (status, body) = call(HttpGet, path, hostCookie)
      check status == 400
      check parseJson(body)["code"].getStr() == "INVALID_INPUT"
    # Body ids go through the same cast when the schedule names players.
    let (_, created) = call(HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Bad ids","date":"2026-11-11"}""")
    let sessionId = parseJson(created)["id"].getStr()
    let (badPlayer, _) = call(HttpPut,
      "/c/sched-club/sessions/" & sessionId & "/schedule", hostCookie,
      """{"games":[{"round":0,"court":0,"sideA":["not-a-uuid"]}]}""",
      ifMatch = "\"1\"")
    check badPlayer == 400

  test "an idempotency key replays the first response, not the second write":
    let (_, created) = call(HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Idempotent","date":"2026-11-12"}""")
    let sessionId = parseJson(created)["id"].getStr()
    let path = "/c/sched-club/sessions/" & sessionId
    let patch = """{"title":"Renamed once"}"""
    let (first, firstBody) = call(HttpPatch, path, hostCookie, patch,
      ifMatch = "\"1\"", idempotencyKey = "patch-once")
    check first == 200
    check parseJson(firstBody)["version"].getInt() == 2
    # The same key and body replay the stored response even though If-Match is
    # stale now, and the write must not run twice.
    let (replay, replayBody) = call(HttpPatch, path, hostCookie, patch,
      ifMatch = "\"1\"", idempotencyKey = "patch-once")
    check replay == 200
    # The stored response comes back as jsonb, so the keys may be reordered.
    let replayed = parseJson(replayBody)
    check replayed["version"].getInt() == 2
    check replayed["title"].getStr() == "Renamed once"
    check replayed["id"].getStr() == parseJson(firstBody)["id"].getStr()
    let (conflict, _) = call(HttpPatch, path, hostCookie,
      """{"title":"Different"}""", ifMatch = "\"1\"",
      idempotencyKey = "patch-once")
    check conflict == 409
    let (_, after) = call(HttpGet, path, hostCookie)
    check parseJson(after)["title"].getStr() == "Renamed once"
    check parseJson(after)["version"].getInt() == 2

  test "creating a session is idempotent per key":
    let path = "/c/sched-club/sessions"
    let body = """{"title":"Replay","date":"2026-11-13"}"""
    let (first, firstBody) = call(HttpPost, path, hostCookie, body,
      idempotencyKey = "create-once")
    check first == 201
    # The same key and body replay the stored response, and no second row.
    let (replay, replayBody) = call(HttpPost, path, hostCookie, body,
      idempotencyKey = "create-once")
    check replay == 201
    check parseJson(replayBody)["id"].getStr() == parseJson(firstBody)["id"].getStr()
    let rows = database.queryOne(
      """select count(*)::int as n from session.sessions
         where community_id = $1::uuid and title = 'Replay'""",
      @[textParam(communityId)])
    check rows.get.get("n") == "1"
    let (conflict, _) = call(HttpPost, path, hostCookie,
      """{"title":"Replay","date":"2026-11-14"}""",
      idempotencyKey = "create-once")
    check conflict == 409
    # A rejected body must not own the key: the corrected retry still works.
    let (rejected, _) = call(HttpPost, path, hostCookie,
      """{"date":"2026-11-15"}""", idempotencyKey = "create-retry")
    check rejected == 400
    let (retried, _) = call(HttpPost, path, hostCookie,
      """{"title":"Retried","date":"2026-11-15"}""",
      idempotencyKey = "create-retry")
    check retried == 201

  test "a sign-off freezes both locking and unlocking":
    let (_, created) = call(HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Signed off","date":"2026-11-16"}""")
    let sessionId = parseJson(created)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]}]}"""
    discard call(HttpPut, "/c/sched-club/sessions/" & sessionId & "/schedule",
      hostCookie, schedule, ifMatch = "\"1\"")
    discard call(HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
      """{"scoreA":21,"scoreB":15}""", ifMatch = "\"2\"")
    let (locked, _) = call(HttpPost,
      "/c/sched-club/sessions/" & sessionId & "/lock", hostCookie,
      ifMatch = "\"3\"")
    check locked == 200
    let before = database.queryOne(
      """select approved_by, approved_at::text as approved_at
         from session.sessions where id = $1::uuid""",
      @[textParam(sessionId)])
    let (finalized, _) = call(HttpPatch,
      "/c/sched-club/rating-sources/" & sessionId, adminCookie,
      """{"finalized":true}""")
    check finalized == 200
    # Neither direction may touch the event or the approval stamp now.
    let (unlockRefused, _) = call(HttpPost,
      "/c/sched-club/sessions/" & sessionId & "/unlock", hostCookie,
      ifMatch = "\"4\"")
    check unlockRefused == 403
    let (lockRefused, _) = call(HttpPost,
      "/c/sched-club/sessions/" & sessionId & "/lock", hostCookie,
      ifMatch = "\"4\"")
    check lockRefused == 403
    let after = database.queryOne(
      """select approved_by, approved_at::text as approved_at
         from session.sessions where id = $1::uuid""",
      @[textParam(sessionId)])
    check after.get.get("approved_by") == before.get.get("approved_by")
    check after.get.get("approved_at") == before.get.get("approved_at")
    let events = database.queryOne(
      """select count(*)::int as n from rating.events
         where community_id = $1::uuid and source_id = $2::uuid""",
      @[textParam(communityId), textParam(sessionId)])
    check events.get.get("n") == "1"

  test "members read the standings and an unknown session is a 404":
    let (created, body) = call(HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Board","date":"2026-11-04"}""")
    check created == 201
    let sessionId = parseJson(body)["id"].getStr()
    for player in [players[0], players[1]]:
      discard database.execUpdate(
        """insert into session.participants
             (community_id, session_id, player_id)
           values ($1::uuid, $2::uuid, $3::uuid)""",
        @[textParam(communityId), textParam(sessionId), textParam(player)])
    discard database.execUpdate(
      """insert into session.games
           (community_id, session_id, round_no, court_no, score_a, score_b,
            status, side_a1, side_b1)
         values ($1::uuid, $2::uuid, 0, 0, 30, 20, 'played', $3::uuid, $4::uuid)""",
      @[textParam(communityId), textParam(sessionId), textParam(players[0]),
        textParam(players[1])])
    let path = "/c/sched-club/sessions/" & sessionId & "/standings"
    let (read, boardBody) = call(HttpGet, path, memberCookie)
    check read == 200
    let board = parseJson(boardBody)
    check board["sessionId"].getStr() == sessionId
    check board["items"].len == 2
    check board["items"][0]["name"].getStr() == "Ani"
    check board["items"][0]["wins"].getInt() == 1
    check board["items"][0]["diff"].getInt() == 10
    check board["items"][1]["wins"].getInt() == 0
    let (anonymous, _) = call(HttpGet, path)
    check anonymous == 401
    let (missing, _) = call(HttpGet,
      "/c/sched-club/sessions/11111111-1111-1111-1111-111111111111/standings",
      memberCookie)
    check missing == 404

  test "finishing a session rates it, reopens it and withdraws the rating":
    let (_, body) = call(HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Finish night","date":"2026-11-10"}""")
    let sessionId = parseJson(body)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]}]}"""
    discard call(HttpPut, "/c/sched-club/sessions/" & sessionId & "/schedule",
      hostCookie, schedule, ifMatch = "\"1\"")
    let (scored, _) = call(HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
      """{"scoreA":21,"scoreB":15}""", ifMatch = "\"2\"")
    check scored == 200
    let events = proc(): string =
      let row = database.queryOne(
        """select count(*)::int as n from rating.events
           where community_id = $1::uuid and event_type = 'session'
             and source_id = $2::uuid""",
        @[textParam(communityId), textParam(sessionId)])
      row.get.get("n")
    check events() == "0"

    # Finishing is the rating gate: approval ingests the session in the same call.
    let lockPath = "/c/sched-club/sessions/" & sessionId & "/lock"
    let (memberRefused, _) = call(HttpPost, lockPath, memberCookie,
      ifMatch = "\"3\"")
    check memberRefused == 403
    let (locked, _) = call(HttpPost, lockPath, hostCookie, ifMatch = "\"3\"")
    check locked == 200
    check events() == "1"

    # A badge on the shelf that this session does not support. The unlock path
    # reconciles achievements after the revert, so the row must be gone.
    discard database.execUpdate(
      """insert into achievement.earned
           (community_id, player_id, achievement_key, earned_at)
         values ($1::uuid, $2::uuid, 'games:200', now())
         on conflict do nothing""",
      @[textParam(communityId), textParam(players[0])])

    # A finished session is read-only: the score has to be reopened first.
    let (writeRefused, _) = call(HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
      """{"scoreA":21,"scoreB":18}""", ifMatch = "\"4\"")
    check writeRefused == 403

    let (reopened, _) = call(HttpPost,
      "/c/sched-club/sessions/" & sessionId & "/unlock", hostCookie,
      ifMatch = "\"4\"")
    check reopened == 200
    check events() == "0"
    let stale = database.queryOne(
      """select 1 as ok from achievement.earned
         where community_id = $1::uuid and player_id = $2::uuid
           and achievement_key = 'games:200'""",
      @[textParam(communityId), textParam(players[0])])
    check stale.isNone

  test "a bundle from another major is told to reload":
    let path = "/c/sched-club/players"
    let (current, _) = call(HttpGet, path, memberCookie, apiVersion = "2")
    check current == 200
    let (older, olderBody) = call(HttpGet, path, memberCookie, apiVersion = "1")
    check older == 410
    check parseJson(olderBody)["code"].getStr() == "CLIENT_OUTDATED"
    # After a rollback the tab is newer than the server, and it is just as
    # unable to talk to it.
    let (newer, _) = call(HttpGet, path, memberCookie, apiVersion = "3")
    check newer == 410
    # No header is a CLI or a probe, never an old bundle.
    let (noHeader, _) = call(HttpGet, path, memberCookie)
    check noHeader == 200
    # Health and version stay reachable so a broken tab can recover.
    let (health, _) = call(HttpGet, "/healthz", apiVersion = "1")
    check health == 200
    let (version, _) = call(HttpGet, "/version", apiVersion = "1")
    check version == 200
