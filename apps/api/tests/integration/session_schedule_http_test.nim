import std/[json, options, strutils, unittest]
import db/db
import community/infrastructure/community_store
import tests/fixtures
import ../http_support

let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  adminEmail = "sched-admin@example.com"
  hostEmail = "sched-host@example.com"
  memberEmail = "sched-member@example.com"

var
  database: Db
  communityId: string
  hostCookie, adminCookie, memberCookie: string
  players: seq[string]
  # BE-05's share re-display read gets a community and a session of its own, so
  # the schedule cases above cannot change what the code it shows is.
  be05CommunityId, be05SessionId, be05EmptySessionId: string
  be05HostCookie, be05MemberCookie: string

proc bootstrap() =
  database = openDb(dsn(), 1)
  # A test may leave a signed-off source behind, and the rating tables hold the
  # community by FK: clear everything the community owns in one place.
  purgeCommunity(database, "sched-club")
  discard database.execUpdate(
    """delete from platform.idempotency_keys where user_id in
         (select id from platform.user where google_sub like 'sched-%')""")
  discard database.execUpdate(
    "delete from platform.user where google_sub like 'sched-%'")
  let ownerId = newUser(database, "sched-owner", "sched-owner@example.com",
    "Owner", owner = true)
  communityId = community_store.create(database, "sched-club", "Schedule Club",
    adminEmail, "Asia/Jakarta", ownerId).communityId
  proc member(sub, email, role: string): string =
    let id = newUser(database, sub, email, sub)
    newMember(database, communityId, id, role)
    id
  adminCookie = cookieFor(database, member("sched-admin", adminEmail, "admin"))
  hostCookie = cookieFor(database, member("sched-host", hostEmail, "host"))
  memberCookie = cookieFor(database,
    member("sched-member", memberEmail, "member"))
  for name in ["Ani", "Budi", "Cakra", "Dewi", "Eka", "Fajar", "Gita", "Hadi"]:
    players.add(newPlayer(database, communityId, name))

  purgeCommunity(database, "be05-share")
  cleanupUsers(database, "be05-share-%")
  be05CommunityId = newCommunity(database, "be05-share", "BE05 Share")
  let be05HostId = newUser(database, "be05-share-host",
    "be05-share-host@example.com", "BE05 Host")
  let be05MemberId = newUser(database, "be05-share-member",
    "be05-share-member@example.com", "BE05 Member")
  newMember(database, be05CommunityId, be05HostId, "host")
  newMember(database, be05CommunityId, be05MemberId, "member")
  be05SessionId = newSession(database, be05CommunityId, "BE05 shared",
    status = "locked", approved = true)
  be05EmptySessionId = newSession(database, be05CommunityId, "BE05 unshared")
  be05HostCookie = cookieFor(database, be05HostId)
  be05MemberCookie = cookieFor(database, be05MemberId)

  startServer(newTestApp(database), port, baseUrl)

bootstrap()

suite "session schedule HTTP":
  test "a real 400 carries the problem envelope":
    let response = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"","date":"2026-11-04"}""")
    expectProblem(response, 400)
    let status = response.status
    let contentType = header(response, "Content-Type")
    let body = response.body
    check contentType.startsWith("application/problem+json")
    let parsed = parseJson(body)
    check parsed["status"].getInt() == status
    check parsed["code"].getStr() == "INVALID_BODY"
    check parsed["i18nKey"].getStr().startsWith("error.")
    check parsed["detail"].getStr() == "title must not be blank"

  test "a host writes a schedule and reads the game back":
    let created = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Wednesday","date":"2026-11-04"}""")
    let body = created.body
    expectStatus(created, 201)
    let sessionId = parseJson(body)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]}]}"""
    let cannotWrite = call(baseUrl, HttpPut,
      "/c/sched-club/sessions/" & sessionId & "/schedule", memberCookie,
      schedule, ifMatch = "\"1\"")
    expectProblem(cannotWrite, 403)
    let written = call(baseUrl, HttpPut,
      "/c/sched-club/sessions/" & sessionId & "/schedule", hostCookie,
      schedule, ifMatch = "\"1\"")
    let writtenBody = written.body
    expectStatus(written, 200)
    check parseJson(writtenBody)["version"].getInt() == 2
    let game = call(baseUrl, HttpGet,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie)
    let gameBody = game.body
    expectStatus(game, 200)
    let parsed = parseJson(gameBody)
    check parsed["sideA"].len == 2
    check parsed["sideA"][0].getStr() == players[0]
    check parsed["status"].getStr() == "scheduled"
    # The detail read carries the schedule, because there is no read endpoint
    # for the schedule itself and a page cannot guess the game keys.
    let detail = call(baseUrl, HttpGet,
      "/c/sched-club/sessions/" & sessionId, hostCookie)
    let detailBody = detail.body
    expectStatus(detail, 200)
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
    let notModified = call(baseUrl, HttpGet,
      "/c/sched-club/sessions/" & sessionId, hostCookie, extra = [("If-None-Match", etag)])
    let notModifiedBody = notModified.body
    expectStatus(notModified, 304)
    check notModifiedBody.len == 0
    let staleEtag = call(baseUrl, HttpGet,
      "/c/sched-club/sessions/" & sessionId, hostCookie, extra = [("If-None-Match", "\"1\"")])
    expectStatus(staleEtag, 200)
    let stale = call(baseUrl, HttpPut,
      "/c/sched-club/sessions/" & sessionId & "/schedule", hostCookie,
      schedule, ifMatch = "\"1\"")
    expectProblem(stale, 412)
    let noPrecondition = call(baseUrl, HttpPut,
      "/c/sched-club/sessions/" & sessionId & "/schedule", hostCookie, schedule)
    expectProblem(noPrecondition, 428)

  test "scores, absence and skipping move the session version":
    let body = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Scored","date":"2026-11-05"}""").body
    let sessionId = parseJson(body)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]}]}"""
    discard call(baseUrl, HttpPut, "/c/sched-club/sessions/" & sessionId & "/schedule",
      hostCookie, schedule, ifMatch = "\"1\"")
    let tie = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
      """{"scoreA":30,"scoreB":30}""", ifMatch = "\"2\"")
    let tieBody = tie.body
    expectProblem(tie, 400)
    check parseJson(tieBody)["code"].getStr() == "INVALID_SCORE"
    for badScore in ["""{"scoreA":-1,"scoreB":5}""", """{"scoreA":100,"scoreB":5}"""]:
      let rejected = call(baseUrl, HttpPatch,
        "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
        badScore, ifMatch = "\"2\"")
      let rejectedBody = rejected.body
      expectProblem(rejected, 400)
      check parseJson(rejectedBody)["code"].getStr() == "INVALID_SCORE"
    let scored = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
      """{"scoreA":30,"scoreB":15}""", ifMatch = "\"2\"")
    expectStatus(scored, 200)
    let gameBody = call(baseUrl, HttpGet,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie).body
    check parseJson(gameBody)["status"].getStr() == "played"
    let absent = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/absent", hostCookie,
      """{"playerIds":["""" & players[3] & """"]}""", ifMatch = "\"3\"")
    expectStatus(absent, 200)
    let skipped = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0/skip", hostCookie,
      """{}""", ifMatch = "\"4\"")
    expectStatus(skipped, 200)
    let afterBody = call(baseUrl, HttpGet,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie).body
    check parseJson(afterBody)["status"].getStr() == "cancelled"
    let unknown = call(baseUrl, HttpPut,
      "/c/sched-club/sessions/" & sessionId & "/schedule", hostCookie,
      """{"games":[{"round":1,"court":0,"sideA":["00000000-0000-0000-0000-000000000000"]}]}""",
      ifMatch = "\"5\"")
    expectProblem(unknown, 400)
    # SEC-07: the writes that decide ranking points are attributable now. One
    # row per successful call, naming the host and the session; a refused call
    # leaves none, so a retry cannot look like a second edit.
    let hostId = database.queryOne(
      "select id from platform.user where google_sub = 'sched-host'").get.get("id")
    for action in ["session.schedule.put", "session.game.score",
                   "session.absent.set", "session.game.skip"]:
      let rows = database.query(
        """select actor_id::text as actor, after->>'count' as count,
                  after->>'gameKey' as game
           from account.audit
           where action = $1 and target_id = $2""",
        @[textParam(action), textParam(sessionId)])
      checkpoint(action)
      check rows.len == 1
      check rows[0].get("actor") == hostId
    let scoreRows = database.query(
      """select after->>'count' as count, after->>'gameKey' as game
         from account.audit
         where action = 'session.game.score' and target_id = $1""",
      @[textParam(sessionId)])
    check scoreRows[0].get("game") == "0-0"
    check scoreRows[0].get("count") == "1"

  test "a failed audit insert rolls the score back":
    # DB-24: a scoring write and its evidence share one transaction now. A
    # trigger that rejects the audit row must take the score with it, or the
    # client would see a 500 for a result that had already landed.
    let created = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Audited","date":"2026-11-06"}""").body
    let sessionId = parseJson(created)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]}]}"""
    expectStatus(call(baseUrl, HttpPut,
      "/c/sched-club/sessions/" & sessionId & "/schedule", hostCookie, schedule,
      ifMatch = "\"1\""), 200)
    discard database.execUpdate(
      """create or replace function t_sched_audit_fail() returns trigger
         language plpgsql as $fn$
         begin
           if new.action = 'session.game.score' then
             raise exception 'injected audit failure' using errcode = 'P0001';
           end if;
           return new;
         end $fn$""")
    discard database.execUpdate(
      """create trigger t_sched_audit_fail before insert on account.audit
         for each row execute function t_sched_audit_fail()""")
    let failed = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
      """{"scoreA":30,"scoreB":15}""", ifMatch = "\"2\"")
    expectStatus(failed, 500)
    discard database.execUpdate("drop trigger t_sched_audit_fail on account.audit")
    discard database.execUpdate("drop function t_sched_audit_fail()")
    let game = database.queryOne(
      """select g.status, s.version,
                (select count(*)::int from session.game_sets x
                 where x.community_id = g.community_id
                   and x.session_id = g.session_id) as sets
         from session.games g
         join session.sessions s
           on s.community_id = g.community_id and s.id = g.session_id
         where g.session_id = $1::uuid and g.round_no = 0 and g.court_no = 0""",
      @[textParam(sessionId)]).get
    check game.get("status") == "scheduled"
    check game.get("version") == "2"
    check game.get("sets") == "0"
    expectStatus(call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
      """{"scoreA":30,"scoreB":15}""", ifMatch = "\"2\""), 200)

  test "a classic session records sets and only counts a finished match":
    let body = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Classic night","date":"2026-11-12","scoringPreset":"classic21"}""").body
    let sessionId = parseJson(body)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]}]}"""
    discard call(baseUrl, HttpPut, "/c/sched-club/sessions/" & sessionId & "/schedule",
      hostCookie, schedule, ifMatch = "\"1\"")
    # A flat score has no meaning when the format is best of three.
    let flat = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
      """{"scoreA":21,"scoreB":19}""", ifMatch = "\"2\"")
    let flatBody = flat.body
    expectProblem(flat, 400)
    check parseJson(flatBody)["code"].getStr() == "SETS_REQUIRED"
    # One set is a partial match: it is stored, but it is not a result yet.
    let partial = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
      """{"sets":[{"a":21,"b":19}]}""", ifMatch = "\"2\"")
    expectStatus(partial, 200)
    let partialGame = call(baseUrl, HttpGet,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie).body
    check parseJson(partialGame)["status"].getStr() == "scheduled"
    check parseJson(partialGame)["sets"].len == 1
    let partialBoard = call(baseUrl, HttpGet,
      "/c/sched-club/sessions/" & sessionId & "/standings", memberCookie).body
    for item in parseJson(partialBoard)["items"]:
      check item["wins"].getInt() == 0
    # The format is part of the result, so a recorded set freezes it.
    let frozen = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId, hostCookie,
      """{"scoringPreset":"majadu30"}""", ifMatch = "\"3\"")
    let frozenBody = frozen.body
    expectProblem(frozen, 409)
    check parseJson(frozenBody)["code"].getStr() == "PRESET_LOCKED"
    # The second set decides the match.
    let done = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
      """{"sets":[{"a":21,"b":19},{"a":21,"b":19}]}""", ifMatch = "\"3\"")
    expectStatus(done, 200)
    let doneGame = call(baseUrl, HttpGet,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie).body
    let finished = parseJson(doneGame)
    check finished["status"].getStr() == "played"
    check finished["sets"].len == 2
    check finished["setsWonA"].getInt() == 2
    check finished["winner"].getStr() == "A"
    # A set played after the match is won is refused, not ignored.
    let extra = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
      """{"sets":[{"a":21,"b":19},{"a":21,"b":19},{"a":21,"b":19}]}""",
      ifMatch = "\"4\"")
    let extraBody = extra.body
    expectProblem(extra, 400)
    check parseJson(extraBody)["code"].getStr() == "INVALID_SET_SEQUENCE"
    # Clearing the sets is the explicit way back to a different format.
    let cleared = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
      """{"sets":[]}""", ifMatch = "\"4\"")
    expectStatus(cleared, 200)
    let changed = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId, hostCookie,
      """{"scoringPreset":"majadu30"}""", ifMatch = "\"5\"")
    expectStatus(changed, 200)
    let changedDetail = call(baseUrl, HttpGet,
      "/c/sched-club/sessions/" & sessionId, hostCookie).body
    check parseJson(changedDetail)["scoring"]["preset"].getStr() == "majadu30"

  test "a per-player skip keeps the game and reports the skipped players":
    let body = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Partial skip","date":"2026-11-08"}""").body
    let sessionId = parseJson(body)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]}]}"""
    discard call(baseUrl, HttpPut, "/c/sched-club/sessions/" & sessionId & "/schedule",
      hostCookie, schedule, ifMatch = "\"1\"")
    let skipped = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0/skip", hostCookie,
      """{"playerIds":["""" & players[0] & """"]}""", ifMatch = "\"2\"")
    expectStatus(skipped, 200)
    let detailBody = call(baseUrl, HttpGet,
      "/c/sched-club/sessions/" & sessionId, hostCookie).body
    let detail = parseJson(detailBody)
    check detail["version"].getInt() == 3
    check detail["games"][0]["status"].getStr() == "scheduled"
    check detail["skippedPlayers"]["0-0"][0].getStr() == players[0]

    let cleared = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0/skip", hostCookie,
      """{"playerIds":[]}""", ifMatch = "\"3\"")
    expectStatus(cleared, 200)
    let afterBody = call(baseUrl, HttpGet,
      "/c/sched-club/sessions/" & sessionId, hostCookie).body
    check parseJson(afterBody)["skippedPlayers"].len == 0

  test "the share payload serves the same board as the member standings":
    let body = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Shared board","date":"2026-11-09"}""").body
    let sessionId = parseJson(body)["id"].getStr()
    let schedule = """{"games":[""" &
      """{"round":0,"court":0,"sideA":["""" & players[0] & """","""" &
        players[1] & """"],"sideB":["""" & players[2] & """","""" &
        players[3] & """"]},""" &
      """{"round":1,"court":0,"sideA":["""" & players[0] & """","""" &
        players[2] & """"],"sideB":["""" & players[1] & """","""" &
        players[3] & """"]}]}"""
    discard call(baseUrl, HttpPut, "/c/sched-club/sessions/" & sessionId & "/schedule",
      hostCookie, schedule, ifMatch = "\"1\"")
    discard call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
      """{"scoreA":30,"scoreB":15}""", ifMatch = "\"2\"")
    discard call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/1-0", hostCookie,
      """{"scoreA":18,"scoreB":30}""", ifMatch = "\"3\"")
    # An absent player leaves the board, and a per-game skip drops one player
    # from one game without cancelling it: both must show up in the public
    # payload exactly as the member route reports them.
    let absent = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/absent", hostCookie,
      """{"playerIds":["""" & players[3] & """"]}""", ifMatch = "\"4\"")
    expectStatus(absent, 200)
    let skipped = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/1-0/skip", hostCookie,
      """{"playerIds":["""" & players[0] & """"]}""", ifMatch = "\"5\"")
    expectStatus(skipped, 200)

    let boardStatus = call(baseUrl, HttpGet,
      "/c/sched-club/sessions/" & sessionId & "/standings", memberCookie)
    let boardBody = boardStatus.body
    expectStatus(boardStatus, 200)
    let memberItems = parseJson(boardBody)["items"]
    check memberItems.len == 3

    # A code may only name an approved session (SEC-09). This case is about the
    # public board matching the member board, so it stamps the approval the host
    # performs after scoring instead of driving the rating gate again.
    discard database.execUpdate(
      """update session.sessions set status = 'locked', approved_at = now()
         where id = $1::uuid""", @[textParam(sessionId)])
    let issued = call(baseUrl, HttpPost,
      "/c/sched-club/sessions/" & sessionId & "/share", hostCookie)
    let issuedBody = issued.body
    expectStatus(issued, 201)
    let code = parseJson(issuedBody)["code"].getStr()
    let shared = call(baseUrl, HttpGet, "/s/" & code)
    let sharedBody = shared.body
    expectStatus(shared, 200)
    let payload = parseJson(sharedBody)
    check payload.hasKey("standings")
    let publicItems = payload["standings"]["items"]
    check publicItems.len == memberItems.len
    for index in 0 ..< publicItems.len:
      # The equality below is the guarantee: the two screens cannot drift.
      var expected = memberItems[index]
      check expected.hasKey("playerId")
      expected.delete("playerId")
      check publicItems[index] == expected

  test "deleting a session is host-for-draft and admin-for-any":
    let created = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Draft to delete","date":"2026-11-06"}""")
    let body = created.body
    expectStatus(created, 201)
    let draftId = parseJson(body)["id"].getStr()
    let denied = call(baseUrl, HttpDelete,
      "/c/sched-club/sessions/" & draftId, memberCookie)
    expectProblem(denied, 403)
    let deleted = call(baseUrl, HttpDelete,
      "/c/sched-club/sessions/" & draftId, hostCookie)
    expectStatus(deleted, 204)
    let gone = call(baseUrl, HttpGet,
      "/c/sched-club/sessions/" & draftId, hostCookie)
    expectProblem(gone, 404)

    let lockedBody = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Locked to delete","date":"2026-11-07"}""").body
    let lockedId = parseJson(lockedBody)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]}]}"""
    discard call(baseUrl, HttpPut, "/c/sched-club/sessions/" & lockedId & "/schedule",
      hostCookie, schedule, ifMatch = "\"1\"")
    discard database.execUpdate(
      """update session.sessions set status = 'locked' where id = $1::uuid""",
      @[textParam(lockedId)])
    let hostRefused = call(baseUrl, HttpDelete,
      "/c/sched-club/sessions/" & lockedId, hostCookie)
    expectProblem(hostRefused, 403)
    let adminDeleted = call(baseUrl, HttpDelete,
      "/c/sched-club/sessions/" & lockedId, adminCookie)
    expectStatus(adminDeleted, 204)
    let games = database.queryOne(
      """select count(*)::int as n from session.games where session_id = $1::uuid""",
      @[textParam(lockedId)])
    check games.get.get("n") == "0"
    let missing = call(baseUrl, HttpDelete,
      "/c/sched-club/sessions/" & lockedId, adminCookie)
    expectProblem(missing, 404)

  test "a swap exchanges players across games and bumps the version":
    let created = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Swap night","date":"2026-11-08"}""").body
    let sessionId = parseJson(created)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]},
      {"round":0,"court":1,"sideA":["""" & players[4] & """","""" &
      players[5] & """"],"sideB":["""" & players[6] & """","""" &
      players[7] & """"]}]}"""
    let written = call(baseUrl, HttpPut,
      "/c/sched-club/sessions/" & sessionId & "/schedule", hostCookie, schedule,
      ifMatch = "\"1\"")
    expectStatus(written, 200)
    let swapBody = """{"type":"player","a":{"slot":0,"court":0,"team":"A","position":0},"b":{"slot":0,"court":1,"team":"A","position":0}}"""
    let path = "/c/sched-club/sessions/" & sessionId & "/swap"
    let noPrecondition = call(baseUrl, HttpPost, path, hostCookie, swapBody)
    expectProblem(noPrecondition, 428)
    let invalid = call(baseUrl, HttpPost, path, hostCookie, """{"type":"nope"}""",
      ifMatch = "\"2\"")
    expectProblem(invalid, 400)
    let swapped = call(baseUrl, HttpPost, path, hostCookie, swapBody,
      ifMatch = "\"2\"")
    let swappedBody = swapped.body
    expectStatus(swapped, 200)
    check parseJson(swappedBody)["version"].getInt() == 3
    let firstGame = call(baseUrl, HttpGet,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie).body
    check parseJson(firstGame)["sideA"][0].getStr() == players[4]
    let secondGame = call(baseUrl, HttpGet,
      "/c/sched-club/sessions/" & sessionId & "/games/0-1", hostCookie).body
    check parseJson(secondGame)["sideA"][0].getStr() == players[0]
    let stale = call(baseUrl, HttpPost, path, hostCookie, swapBody,
      ifMatch = "\"2\"")
    expectProblem(stale, 412)
    let memberDenied = call(baseUrl, HttpPost, path, memberCookie, swapBody,
      ifMatch = "\"3\"")
    expectProblem(memberDenied, 403)
    discard database.execUpdate(
      """update session.sessions set status = 'locked' where id = $1::uuid""",
      @[textParam(sessionId)])
    let locked = call(baseUrl, HttpPost, path, hostCookie, swapBody,
      ifMatch = "\"3\"")
    expectProblem(locked, 403)

  test "creating a session rejects invalid input with a 400":
    let path = "/c/sched-club/sessions"
    let missingDate = call(baseUrl, HttpPost, path, hostCookie, """{"title":"x"}""")
    expectProblem(missingDate, 400)
    let badDate = call(baseUrl, HttpPost, path, hostCookie,
      """{"date":"2026-02-30"}""")
    expectProblem(badDate, 400)
    let badTime = call(baseUrl, HttpPost, path, hostCookie,
      """{"date":"2026-11-04","startTime":"9:00"}""")
    expectProblem(badTime, 400)
    let badSlot = call(baseUrl, HttpPost, path, hostCookie,
      """{"date":"2026-11-04","slotMinutes":0}""")
    expectProblem(badSlot, 400)
    let tooBig = call(baseUrl, HttpPost, path, hostCookie,
      """{"date":"2026-11-04","slotMinutes":241}""")
    expectProblem(tooBig, 400)
    let badJson = call(baseUrl, HttpPost, path, hostCookie, "{")
    expectProblem(badJson, 400)
    let wrongType = call(baseUrl, HttpPost, path, hostCookie,
      """{"date":20261104}""")
    expectProblem(wrongType, 400)
    # A title is required now: a blank one used to create a nameless draft.
    let noTitle = call(baseUrl, HttpPost, path, hostCookie,
      """{"date":"2026-11-04"}""")
    expectProblem(noTitle, 400)
    let blankTitle = call(baseUrl, HttpPost, path, hostCookie,
      """{"title":"   ","date":"2026-11-04"}""")
    expectProblem(blankTitle, 400)
    let longTitle = call(baseUrl, HttpPost, path, hostCookie,
      """{"title":"""" & "x".repeat(121) &
      """","date":"2026-11-04"}""")
    expectProblem(longTitle, 400)
    let created = call(baseUrl, HttpPost, path, hostCookie,
      """{"title":"Valid","date":"2026-11-04","startTime":"19:30","slotMinutes":45}""")
    let body = created.body
    expectStatus(created, 201)
    check parseJson(body)["date"].getStr() == "2026-11-04"
    # The detail route reads a time as HH:MM:SS, so that shape must round-trip
    # through a patch instead of being rejected as malformed.
    let sessionId = parseJson(body)["id"].getStr()
    let patched = call(baseUrl, HttpPatch, path & "/" & sessionId,
      hostCookie, """{"startTime":"18:45:00"}""", ifMatch = "\"1\"")
    let patchedBody = patched.body
    expectStatus(patched, 200)
    check parseJson(patchedBody)["startTime"].getStr() == "18:45:00"
    # The stored value keeps minute precision; the detail route renders HH:MM.
    let detail = call(baseUrl, HttpGet, path & "/" & sessionId, hostCookie).body
    check parseJson(detail)["startTime"].getStr() == "18:45"
    # Seconds outside zero are refused rather than silently truncated.
    let withSeconds = call(baseUrl, HttpPatch, path & "/" & sessionId, hostCookie,
      """{"startTime":"18:45:30"}""", ifMatch = "\"2\"")
    expectProblem(withSeconds, 400)

  test "a malformed id is a 400 and never reaches the database":
    # The route casts every id to uuid; PostgreSQL's 22P02 used to surface as a
    # 500, which hid a caller mistake behind an internal error.
    for path in ["/c/sched-club/sessions/not-a-uuid",
                 "/c/sched-club/sessions/not-a-uuid/standings",
                 "/c/sched-club/tournaments/not-a-uuid"]:
      let status = call(baseUrl, HttpGet, path, hostCookie)
      let body = status.body
      expectProblem(status, 400)
      check parseJson(body)["code"].getStr() == "INVALID_INPUT"
    # Body ids go through the same cast when the schedule names players.
    let created = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Bad ids","date":"2026-11-11"}""").body
    let sessionId = parseJson(created)["id"].getStr()
    let badPlayer = call(baseUrl, HttpPut,
      "/c/sched-club/sessions/" & sessionId & "/schedule", hostCookie,
      """{"games":[{"round":0,"court":0,"sideA":["not-a-uuid"]}]}""",
      ifMatch = "\"1\"")
    expectProblem(badPlayer, 400)

  test "an idempotency key replays the first response, not the second write":
    let created = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Idempotent","date":"2026-11-12"}""").body
    let sessionId = parseJson(created)["id"].getStr()
    let path = "/c/sched-club/sessions/" & sessionId
    let patch = """{"title":"Renamed once"}"""
    let first = call(baseUrl, HttpPatch, path, hostCookie, patch,
      ifMatch = "\"1\"", extra = [("Idempotency-Key", "patch-once")])
    let firstBody = first.body
    expectStatus(first, 200)
    check parseJson(firstBody)["version"].getInt() == 2
    # The same key and body replay the stored response even though If-Match is
    # stale now, and the write must not run twice.
    let replay = call(baseUrl, HttpPatch, path, hostCookie, patch,
      ifMatch = "\"1\"", extra = [("Idempotency-Key", "patch-once")])
    let replayBody = replay.body
    expectStatus(replay, 200)
    # The stored response comes back as jsonb, so the keys may be reordered.
    let replayed = parseJson(replayBody)
    check replayed["version"].getInt() == 2
    check replayed["title"].getStr() == "Renamed once"
    check replayed["id"].getStr() == parseJson(firstBody)["id"].getStr()
    let conflict = call(baseUrl, HttpPatch, path, hostCookie,
      """{"title":"Different"}""", ifMatch = "\"1\"",
      extra = [("Idempotency-Key", "patch-once")])
    expectProblem(conflict, 409)
    let after = call(baseUrl, HttpGet, path, hostCookie).body
    check parseJson(after)["title"].getStr() == "Renamed once"
    check parseJson(after)["version"].getInt() == 2

  test "creating a session is idempotent per key":
    let path = "/c/sched-club/sessions"
    let body = """{"title":"Replay","date":"2026-11-13"}"""
    let first = call(baseUrl, HttpPost, path, hostCookie, body,
      extra = [("Idempotency-Key", "create-once")])
    let firstBody = first.body
    expectStatus(first, 201)
    # The same key and body replay the stored response, and no second row.
    let replay = call(baseUrl, HttpPost, path, hostCookie, body,
      extra = [("Idempotency-Key", "create-once")])
    let replayBody = replay.body
    expectStatus(replay, 201)
    check parseJson(replayBody)["id"].getStr() == parseJson(firstBody)["id"].getStr()
    let rows = database.queryOne(
      """select count(*)::int as n from session.sessions
         where community_id = $1::uuid and title = 'Replay'""",
      @[textParam(communityId)])
    check rows.get.get("n") == "1"
    let conflict = call(baseUrl, HttpPost, path, hostCookie,
      """{"title":"Replay","date":"2026-11-14"}""",
      extra = [("Idempotency-Key", "create-once")])
    expectProblem(conflict, 409)
    # A rejected body must not own the key: the corrected retry still works.
    let rejected = call(baseUrl, HttpPost, path, hostCookie,
      """{"date":"2026-11-15"}""", extra = [("Idempotency-Key", "create-retry")])
    expectProblem(rejected, 400)
    let retried = call(baseUrl, HttpPost, path, hostCookie,
      """{"title":"Retried","date":"2026-11-15"}""",
      extra = [("Idempotency-Key", "create-retry")])
    expectStatus(retried, 201)

  test "a draft with no rating cannot be signed off":
    let created = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Unsigned draft","date":"2026-11-17"}""").body
    let draftId = parseJson(created)["id"].getStr()
    let refused = call(baseUrl, HttpPatch,
      "/c/sched-club/rating-sources/" & draftId, adminCookie,
      """{"finalized":true}""")
    let body = refused.body
    # Otherwise the flag is invisible in the ledger while blocking delete, and a
    # later lock creates the result under a sign-off recorded before it existed.
    expectProblem(refused, 409)
    check parseJson(body)["code"].getStr() == "NOT_RATED"
    let deleted = call(baseUrl, HttpDelete, "/c/sched-club/sessions/" & draftId,
      hostCookie)
    expectStatus(deleted, 204)

  test "a sign-off freezes both locking and unlocking":
    let created = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Signed off","date":"2026-11-16"}""").body
    let sessionId = parseJson(created)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]}]}"""
    discard call(baseUrl, HttpPut, "/c/sched-club/sessions/" & sessionId & "/schedule",
      hostCookie, schedule, ifMatch = "\"1\"")
    discard call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
      """{"scoreA":30,"scoreB":15}""", ifMatch = "\"2\"")
    let locked = call(baseUrl, HttpPost,
      "/c/sched-club/sessions/" & sessionId & "/lock", hostCookie,
      ifMatch = "\"3\"")
    expectStatus(locked, 200)
    let before = database.queryOne(
      """select approved_by, approved_at::text as approved_at
         from session.sessions where id = $1::uuid""",
      @[textParam(sessionId)])
    let finalized = call(baseUrl, HttpPatch,
      "/c/sched-club/rating-sources/" & sessionId, adminCookie,
      """{"finalized":true}""")
    expectStatus(finalized, 200)
    # Neither direction may touch the event or the approval stamp now.
    let unlockRefused = call(baseUrl, HttpPost,
      "/c/sched-club/sessions/" & sessionId & "/unlock", hostCookie,
      ifMatch = "\"4\"")
    expectProblem(unlockRefused, 403)
    let lockRefused = call(baseUrl, HttpPost,
      "/c/sched-club/sessions/" & sessionId & "/lock", hostCookie,
      ifMatch = "\"4\"")
    expectProblem(lockRefused, 403)
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

  test "an idempotency key does not leak between sessions":
    let path = "/c/sched-club/sessions"
    let firstBody = call(baseUrl, HttpPost, path, hostCookie,
      """{"title":"Scoped A","date":"2026-11-18"}""").body
    let secondBody = call(baseUrl, HttpPost, path, hostCookie,
      """{"title":"Scoped B","date":"2026-11-19"}""").body
    let firstId = parseJson(firstBody)["id"].getStr()
    let secondId = parseJson(secondBody)["id"].getStr()
    let patch = """{"title":"Scoped A"}"""
    let applied = call(baseUrl, HttpPatch, path & "/" & firstId, hostCookie, patch,
      ifMatch = "\"1\"", extra = [("Idempotency-Key", "shared-key")])
    expectStatus(applied, 200)
    # The same key and body against another session must run, not replay A.
    let other = call(baseUrl, HttpPatch, path & "/" & secondId, hostCookie,
      patch, ifMatch = "\"1\"", extra = [("Idempotency-Key", "shared-key")])
    let otherBody = other.body
    expectStatus(other, 200)
    check parseJson(otherBody)["id"].getStr() == secondId
    let stored = call(baseUrl, HttpGet, path & "/" & secondId, hostCookie).body
    check parseJson(stored)["title"].getStr() == "Scoped A"

  test "a rejected idempotent patch releases the key":
    let path = "/c/sched-club/sessions"
    let created = call(baseUrl, HttpPost, path, hostCookie,
      """{"title":"Retry me","date":"2026-11-20"}""").body
    let sessionId = parseJson(created)["id"].getStr()
    let patchPath = path & "/" & sessionId
    let rejected = call(baseUrl, HttpPatch, patchPath, hostCookie,
      """{"date":"2026-02-30"}""", ifMatch = "\"1\"",
      extra = [("Idempotency-Key", "retry-after-400")])
    expectProblem(rejected, 400)
    # The corrected retry must run, not answer 409 because the failed attempt
    # still owned the key.
    let retried = call(baseUrl, HttpPatch, patchPath, hostCookie,
      """{"title":"Retried"}""", ifMatch = "\"1\"",
      extra = [("Idempotency-Key", "retry-after-400")])
    let retriedBody = retried.body
    expectStatus(retried, 200)
    check parseJson(retriedBody)["title"].getStr() == "Retried"

  test "search treats LIKE wildcards literally":
    discard call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Percent 100%","date":"2026-11-21"}""")
    discard call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Plain night","date":"2026-11-22"}""")
    let matches = call(baseUrl, HttpGet, "/c/sched-club/sessions?q=100%25",
      hostCookie).body
    let matchPage = parseJson(matches)
    check matchPage["items"].len == 1
    check matchPage["items"][0]["title"].getStr() == "Percent 100%"
    check matchPage["total"].getInt() == 1
    # A bare "%" only matches a title that really contains one.
    let percentOnly = call(baseUrl, HttpGet, "/c/sched-club/sessions?q=%25",
      hostCookie).body
    let percentPage = parseJson(percentOnly)
    check percentPage["items"].len == 1
    check percentPage["total"].getInt() == 1
    let underscore = call(baseUrl, HttpGet, "/c/sched-club/sessions?q=_",
      hostCookie).body
    let underscorePage = parseJson(underscore)
    check underscorePage["items"].len == 0
    check underscorePage["total"].getInt() == 0

  test "a malformed If-Match is a 400, not a missing precondition":
    let created = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Precondition","date":"2026-11-23"}""").body
    let sessionId = parseJson(created)["id"].getStr()
    let path = "/c/sched-club/sessions/" & sessionId
    let malformed = call(baseUrl, HttpPatch, path, hostCookie,
      """{"title":"Nope"}""", ifMatch = "\"abc\"")
    let malformedBody = malformed.body
    expectProblem(malformed, 400)
    check parseJson(malformedBody)["code"].getStr() == "INVALID_PRECONDITION"
    let missing = call(baseUrl, HttpPatch, path, hostCookie, """{"title":"Nope"}""")
    expectProblem(missing, 428)

  test "a weak validator is refused and changes nothing":
    # BE-21: `W/"1"` used to parse as version 1 because the old reader stripped
    # the prefix. A weak validator may not be byte-identical, so honouring it
    # defeats the check that protects a concurrent edit.
    let created = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"WeakEtag","date":"2026-11-24"}""").body
    let sessionId = parseJson(created)["id"].getStr()
    let path = "/c/sched-club/sessions/" & sessionId
    let weak = call(baseUrl, HttpPatch, path, hostCookie,
      """{"title":"Overwritten"}""", ifMatch = "W/\"1\"")
    expectProblem(weak, 400)
    check parseJson(weak.body)["code"].getStr() == "INVALID_PRECONDITION"
    let unchanged = parseJson(call(baseUrl, HttpGet, path, hostCookie).body)
    check unchanged["title"].getStr() == "WeakEtag"
    # `*` names no version, so it is refused rather than treated as "any".
    let star = call(baseUrl, HttpPatch, path, hostCookie,
      """{"title":"Overwritten"}""", ifMatch = "*")
    expectProblem(star, 400)
    check parseJson(call(baseUrl, HttpGet, path, hostCookie).body)["title"].getStr() ==
      "WeakEtag"

  test "a player outside the session cannot be marked absent":
    let created = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Absent night","date":"2026-11-24"}""").body
    let sessionId = parseJson(created)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]}]}"""
    let written = call(baseUrl, HttpPut,
      "/c/sched-club/sessions/" & sessionId & "/schedule", hostCookie, schedule,
      ifMatch = "\"1\"")
    expectStatus(written, 200)
    let path = "/c/sched-club/sessions/" & sessionId & "/absent"
    let unknown = call(baseUrl, HttpPatch, path, hostCookie,
      """{"playerIds":["""" & players[4] & """"]}""", ifMatch = "\"2\"")
    let unknownBody = unknown.body
    expectProblem(unknown, 400)
    check parseJson(unknownBody)["code"].getStr() == "NOT_PARTICIPANT"
    # A rejected write must not bump the version.
    let read = call(baseUrl, HttpGet, "/c/sched-club/sessions/" & sessionId,
      hostCookie).body
    check parseJson(read)["version"].getInt() == 2
    let knownStatus = call(baseUrl, HttpPatch, path, hostCookie,
      """{"playerIds":["""" & players[0] & """"]}""", ifMatch = "\"2\"")
    let knownBody = knownStatus.body
    expectStatus(knownStatus, 200)
    check parseJson(knownBody)["version"].getInt() == 3

    # The same participant rule applies to a per-game skip.
    let skipUnknown = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0/skip", hostCookie,
      """{"playerIds":["""" & players[4] & """"]}""", ifMatch = "\"3\"")
    let skipBody = skipUnknown.body
    expectProblem(skipUnknown, 400)
    check parseJson(skipBody)["code"].getStr() == "NOT_PARTICIPANT"

  test "a swap naming a game that does not exist is a 404":
    let created = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Missing game","date":"2026-11-25"}""").body
    let sessionId = parseJson(created)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]}]}"""
    discard call(baseUrl, HttpPut, "/c/sched-club/sessions/" & sessionId & "/schedule",
      hostCookie, schedule, ifMatch = "\"1\"")
    let missing = call(baseUrl, HttpPost,
      "/c/sched-club/sessions/" & sessionId & "/swap", hostCookie,
      """{"type":"slot","a":{"slot":9,"court":9},"b":{"slot":0,"court":0}}""",
      ifMatch = "\"2\"")
    expectProblem(missing, 404)

  test "members read the standings and an unknown session is a 404":
    let created = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Board","date":"2026-11-04"}""")
    let body = created.body
    expectStatus(created, 201)
    let sessionId = parseJson(body)["id"].getStr()
    for player in [players[0], players[1]]:
      discard database.execUpdate(
        """insert into session.participants
             (community_id, session_id, player_id)
           values ($1::uuid, $2::uuid, $3::uuid)""",
        @[textParam(communityId), textParam(sessionId), textParam(player)])
    newGame(database, communityId, sessionId, 0, 0, [players[0]],
      [players[1]], status = "played", scoreA = 30, scoreB = 20)
    discard database.execUpdate(
      """insert into session.game_sets
           (community_id, session_id, round_no, court_no, set_no, score_a, score_b)
         values ($1::uuid, $2::uuid, 0, 0, 1, 30, 20)""",
      @[textParam(communityId), textParam(sessionId)])
    let path = "/c/sched-club/sessions/" & sessionId & "/standings"
    let read = call(baseUrl, HttpGet, path, memberCookie)
    let boardBody = read.body
    expectStatus(read, 200)
    let board = parseJson(boardBody)
    check board["sessionId"].getStr() == sessionId
    check board["items"].len == 2
    check board["items"][0]["name"].getStr() == "Ani"
    check board["items"][0]["wins"].getInt() == 1
    check board["items"][0]["diff"].getInt() == 10
    check board["items"][1]["wins"].getInt() == 0
    let anonymous = call(baseUrl, HttpGet, path)
    expectProblem(anonymous, 401)
    let missing = call(baseUrl, HttpGet,
      "/c/sched-club/sessions/11111111-1111-1111-1111-111111111111/standings",
      memberCookie)
    expectProblem(missing, 404)

  test "finishing a session rates it, reopens it and withdraws the rating":
    let body = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Finish night","date":"2026-11-10"}""").body
    let sessionId = parseJson(body)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]}]}"""
    discard call(baseUrl, HttpPut, "/c/sched-club/sessions/" & sessionId & "/schedule",
      hostCookie, schedule, ifMatch = "\"1\"")
    let scored = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
      """{"scoreA":30,"scoreB":15}""", ifMatch = "\"2\"")
    expectStatus(scored, 200)
    let events = proc(): string =
      let row = database.queryOne(
        """select count(*)::int as n from rating.events
           where community_id = $1::uuid and event_type = 'session'
             and source_id = $2::uuid""",
        @[textParam(communityId), textParam(sessionId)])
      row.get.get("n")
    check events() == "0"

    let draftIngest = call(baseUrl, HttpPost,
      "/c/sched-club/sessions/" & sessionId & "/rating", adminCookie)
    let draftBody = draftIngest.body
    expectProblem(draftIngest, 409)
    check parseJson(draftBody)["code"].getStr() == "CONFLICT"

    # Finishing is the rating gate: approval ingests the session in the same call.
    let lockPath = "/c/sched-club/sessions/" & sessionId & "/lock"
    let memberRefused = call(baseUrl, HttpPost, lockPath, memberCookie,
      ifMatch = "\"3\"")
    expectProblem(memberRefused, 403)
    let locked = call(baseUrl, HttpPost, lockPath, hostCookie, ifMatch = "\"3\"")
    expectStatus(locked, 200)
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
    let writeRefused = call(baseUrl, HttpPatch,
      "/c/sched-club/sessions/" & sessionId & "/games/0-0", hostCookie,
      """{"scoreA":30,"scoreB":18}""", ifMatch = "\"4\"")
    expectProblem(writeRefused, 403)

    let reopened = call(baseUrl, HttpPost,
      "/c/sched-club/sessions/" & sessionId & "/unlock", hostCookie,
      ifMatch = "\"4\"")
    expectStatus(reopened, 200)
    check events() == "0"
    # The badge shelf is reconciled by the rating worker after the response.
    waitForRatingJobs()
    check database.queryOne(
      """select 1 as ok from achievement.earned
         where community_id = $1::uuid and player_id = $2::uuid
           and achievement_key = 'games:200'""",
      @[textParam(communityId), textParam(players[0])]).isNone

  test "locking a session without a playable game writes no event":
    let created = call(baseUrl, HttpPost, "/c/sched-club/sessions", hostCookie,
      """{"title":"Empty night","date":"2026-11-26"}""").body
    let sessionId = parseJson(created)["id"].getStr()
    let locked = call(baseUrl, HttpPost,
      "/c/sched-club/sessions/" & sessionId & "/lock", hostCookie,
      ifMatch = "\"1\"")
    expectStatus(locked, 200)
    let row = database.queryOne(
      """select count(*)::int as n from rating.events
         where community_id = $1::uuid and event_type = 'session'
           and source_id = $2::uuid""",
      @[textParam(communityId), textParam(sessionId)])
    check row.get.get("n") == "0"

  test "a bundle from another major is told to reload":
    let path = "/c/sched-club/players"
    let current = call(baseUrl, HttpGet, path, memberCookie, extra = [("X-API-Version", "2")])
    expectStatus(current, 200)
    let older = call(baseUrl, HttpGet, path, memberCookie, extra = [("X-API-Version", "1")])
    let olderBody = older.body
    expectProblem(older, 410)
    check parseJson(olderBody)["code"].getStr() == "CLIENT_OUTDATED"
    # After a rollback the tab is newer than the server, and it is just as
    # unable to talk to it.
    let newer = call(baseUrl, HttpGet, path, memberCookie, extra = [("X-API-Version", "3")])
    expectProblem(newer, 410)
    # No header is a CLI or a probe, never an old bundle.
    let noHeader = call(baseUrl, HttpGet, path, memberCookie)
    expectStatus(noHeader, 200)
    # Health and version stay reachable so a broken tab can recover.
    let health = call(baseUrl, HttpGet, "/healthz", extra = [("X-API-Version", "1")])
    expectStatus(health, 200)
    let version = call(baseUrl, HttpGet, "/version", extra = [("X-API-Version", "1")])
    expectStatus(version, 200)

  test "the share read re-displays the live code and 404s when there is none":
    let path = "/c/be05-share/sessions/" & be05SessionId & "/share"
    let noneYet = call(baseUrl, HttpGet, path, be05HostCookie)
    expectProblem(noneYet, 404, "NOT_FOUND")
    let issued = call(baseUrl, HttpPost, path, be05HostCookie)
    let issuedBody = issued.body
    expectStatus(issued, 201)
    let code = parseJson(issuedBody)["code"].getStr()
    let shown = call(baseUrl, HttpGet, path, be05HostCookie)
    let shownBody = shown.body
    expectStatus(shown, 200)
    let payload = parseJson(shownBody)
    # The same code the issue answered with, and the row it belongs to.
    check payload["code"].getStr() == code
    check payload["sessionId"].getStr() == be05SessionId
    # Re-display is a host/admin read; a plain member is refused.
    let asMember = call(baseUrl, HttpGet, path, be05MemberCookie)
    expectProblem(asMember, 403)
    let anonymous = call(baseUrl, HttpGet, path)
    expectProblem(anonymous, 401)
    # A session that never had a link has nothing to show.
    let unshared = call(baseUrl, HttpGet,
      "/c/be05-share/sessions/" & be05EmptySessionId & "/share", be05HostCookie)
    expectProblem(unshared, 404, "NOT_FOUND")
    # Every re-display is audited, so the code cannot leave unnoticed.
    let redisplayAudits = database.queryOne(
      """select count(*) as n from account.audit
         where action = 'share.redisplay' and community_id = $1::uuid
           and target_id = $2""",
      @[textParam(be05CommunityId), textParam(be05SessionId)]).get.getInt("n")
    check redisplayAudits == 1
    # SEC-09: a session moved out of the shareable set stops answering at once.
    # Otherwise an archived season keeps publishing for the rest of the TTL.
    discard database.execUpdate(
      "update session.sessions set status = 'archived' where id = $1::uuid",
      @[textParam(be05SessionId)])
    let archived = call(baseUrl, HttpGet, "/s/" & code)
    expectProblem(archived, 404, "NOT_FOUND")
    discard database.execUpdate(
      "update session.sessions set status = 'locked' where id = $1::uuid",
      @[textParam(be05SessionId)])
    expectStatus(call(baseUrl, HttpGet, "/s/" & code), 200)
    let revoked = call(baseUrl, HttpDelete, path, be05HostCookie)
    expectStatus(revoked, 204)
    let gone = call(baseUrl, HttpGet, path, be05HostCookie)
    expectProblem(gone, 404, "NOT_FOUND")
    purgeCommunity(database, "be05-share")
    cleanupUsers(database, "be05-share-%")
