import std/[json, options, os, unittest]
import db/db
import ../../write
import ../../scoring

proc dsn(): string = getEnv("MAJADU_PG_DSN")

suite "session write":
  var db: Db
  var communityId, sessionId, userId: string

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    discard db.execUpdate(
      "delete from session.sessions where community_id in (select id from platform.community where slug = 'write-test')")
    discard db.execUpdate("delete from platform.community where slug = 'write-test'")
    discard db.execUpdate("delete from platform.user where google_sub = 'write-test'")
    userId = db.queryOne(
      """insert into platform.user (google_sub, email_hash, display_name)
         values ('write-test', 'write-hash', 'Writer') returning id""").get.get("id")
    communityId = db.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ('write-test', 'Write Test', 'Asia/Jakarta') returning id""").get.get("id")
    sessionId = db.queryOne(
      """insert into session.sessions
           (community_id, title, session_date, start_time, slot_minutes, status, source)
         values ($1::uuid, 'Original', '2026-11-03', '19:00', 30, 'draft', 'manual')
         returning id""", @[textParam(communityId)]).get.get("id")

  teardown:
    db.close()

  test "patch updates fields and bumps the version":
    let result = patch(db, communityId, sessionId, 1,
      SessionPatch(title: some("Renamed"), slotMinutes: some(45)))
    check result.status == wsOk
    check result.record["title"].getStr() == "Renamed"
    check result.record["slotMinutes"].getInt() == 45
    check result.record["version"].getInt() == 2

  test "a preset patch stores its own id and rules":
    # The body carries only `scoringPreset`; the route resolves it into rules
    # before calling `patch`, and both columns come from that one value.
    let classic = parsePresetNode(%*{
      "id": "classic21",
      "label": "Classic BO3 21",
      "gamesToWin": 2,
      "pointsToWin": 21,
      "winBy": 2,
      "deuceAt": 20,
      "maxPoints": 30,
      "changeEndsAt": 11}, "test")
    let result = patch(db, communityId, sessionId, 1,
      SessionPatch(scoringPreset: some("classic21"),
        scoringRules: some(classic)))
    check result.status == wsOk
    let stored = db.queryOne(
      """select scoring_preset, scoring_rules->>'id' as rules_id
         from session.sessions where id = $1::uuid""",
      @[textParam(sessionId)]).get
    check stored.get("scoring_preset") == "classic21"
    check stored.get("rules_id") == "classic21"
    # An id that disagrees with the resolved format cannot reach the column.
    let mismatch = patch(db, communityId, sessionId, 2,
      SessionPatch(scoringPreset: some("majadu30"),
        scoringRules: some(classic)))
    check mismatch.status == wsOk
    let kept = db.queryOne(
      """select scoring_preset, scoring_rules->>'id' as rules_id
         from session.sessions where id = $1::uuid""",
      @[textParam(sessionId)]).get
    check kept.get("scoring_preset") == "classic21"
    check kept.get("rules_id") == "classic21"

  test "a stale version does not write and reports staleness":
    check patch(db, communityId, sessionId, 1,
      SessionPatch(title: some("First"))).status == wsOk
    let stale = patch(db, communityId, sessionId, 1,
      SessionPatch(title: some("Second")))
    check stale.status == wsStale
    let current = db.queryOne(
      "select title, version from session.sessions where id = $1::uuid",
      @[textParam(sessionId)]).get
    check current.get("title") == "First"
    check current.get("version") == "2"

  test "an unknown session is not found":
    check patch(db, communityId, "11111111-1111-1111-1111-111111111111", 1,
      SessionPatch(title: some("x"))).status == wsNotFound

  test "lock stamps approved_at and approved_by, unlock clears them":
    let locked = setLock(db, communityId, sessionId, userId, 1, locked = true)
    check locked.status == wsOk
    check locked.record["status"].getStr() == "locked"
    check locked.record["approvedAt"].kind == JString
    check locked.record["version"].getInt() == 2

    let unlocked = setLock(db, communityId, sessionId, userId, 2, locked = false)
    check unlocked.status == wsOk
    check unlocked.record["status"].getStr() == "draft"
    check unlocked.record["approvedAt"].kind == JNull

  test "lock writes no rating event":
    discard setLock(db, communityId, sessionId, userId, 1, locked = true)
    let events = db.queryOne(
      """select count(*) as total from rating.events
         where community_id = $1::uuid""", @[textParam(communityId)]).get
    check events.get("total") == "0"

  test "a rated session keeps its date until it is unlocked":
    check setLock(db, communityId, sessionId, userId, 1, locked = true).status == wsOk
    # The ledger copied the date at ingest, so a rated source may not move it.
    let blocked = patch(db, communityId, sessionId, 2,
      SessionPatch(date: some("2026-11-20")))
    check blocked.status == wsInvalid
    let kept = db.queryOne(
      """select session_date::text as session_date, version
         from session.sessions where id = $1::uuid""",
      @[textParam(sessionId)]).get
    check kept.get("session_date") == "2026-11-03"
    check kept.get("version") == "2"
    # Every other field stays editable while the session is rated.
    check patch(db, communityId, sessionId, 2,
      SessionPatch(title: some("Rated rename"))).status == wsOk
    # Unlocking withdraws the event, so the date may move afterwards.
    check setLock(db, communityId, sessionId, userId, 3,
      locked = false).status == wsOk
    let moved = patch(db, communityId, sessionId, 4,
      SessionPatch(date: some("2026-11-20")))
    check moved.status == wsOk
    check moved.record["date"].getStr() == "2026-11-20"

  test "patch keeps the row identity and child rows":
    let gamesBefore = db.queryOne(
      "select count(*) as total from session.games where session_id = $1::uuid",
      @[textParam(sessionId)]).get.get("total")
    discard patch(db, communityId, sessionId, 1, SessionPatch(title: some("Kept")))
    check db.queryOne(
      "select id from session.sessions where id = $1::uuid",
      @[textParam(sessionId)]).isSome
    check db.queryOne(
      "select count(*) as total from session.games where session_id = $1::uuid",
      @[textParam(sessionId)]).get.get("total") == gamesBefore
