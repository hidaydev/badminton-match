import std/[options, os, unittest]
import db/db
import ../../schedule

proc dsn(): string = getEnv("MAJADU_PG_DSN")

const slug = "schedule-test"

suite "session schedule":
  var db: Db
  var communityId, sessionId: string

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    discard db.execUpdate(
      "delete from session.sessions where community_id in (select id from platform.community where slug = 'schedule-test')")
    discard db.execUpdate("delete from platform.community where slug = 'schedule-test'")
    communityId = db.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ('schedule-test', 'Schedule Test', 'Asia/Jakarta') returning id""")
      .get.get("id")
    sessionId = db.queryOne(
      """insert into session.sessions
           (community_id, title, session_date, start_time, slot_minutes, status, source)
         values ($1::uuid, 'Schedule night', '2026-11-03', '19:00', 30, 'draft', 'manual')
         returning id""", @[textParam(communityId)]).get.get("id")

  teardown:
    db.close()

  proc version(): string =
    db.queryOne(
      "select version from session.sessions where id = $1::uuid",
      @[textParam(sessionId)]).get.get("version")

  test "a missing game answers not found without bumping the version":
    check setScore(db, communityId, sessionId, "0-0", 1, 21, 15) == ssNotFound
    check version() == "1"
    check setPlayed(db, communityId, sessionId, "0-0", 1, true) == ssNotFound
    check version() == "1"