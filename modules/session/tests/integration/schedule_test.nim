import std/[options, os, strutils, unittest]
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
    discard db.execUpdate(
      "delete from player.players where community_id in (select id from platform.community where slug = 'schedule-test')")
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

  proc addPlayer(name: string): string =
    db.queryOne(
      """insert into player.players (community_id, canonical_name)
         values ($1::uuid, $2) returning id""",
      @[textParam(communityId), textParam(name)]).get.get("id")

  proc skips(): seq[string] =
    let row = db.queryOne(
      """select coalesce(array_agg(player_id::text order by player_id), '{}')::text as ids
         from session.game_skips
         where community_id = $1::uuid and session_id = $2::uuid""",
      @[textParam(communityId), textParam(sessionId)])
    if row.isNone or not row.get["ids"].isSome:
      return @[]
    let raw = row.get.get("ids")
    if raw.len <= 2:
      return @[]
    raw[1 ..< raw.len - 1].split(',')

  proc absent(playerId: string): bool =
    db.queryOne(
      """select is_absent from session.participants
         where community_id = $1::uuid and session_id = $2::uuid
           and player_id = $3::uuid""",
      @[textParam(communityId), textParam(sessionId),
        textParam(playerId)]).get.getBool("is_absent")

  test "rewriting the sides drops a skip that named a player who left the game":
    let kept = addPlayer("Kept Player")
    let dropped = addPlayer("Dropped Player")
    let other = addPlayer("Other Player")
    check putSchedule(db, communityId, sessionId, 1, @[
      GameSpec(round: 0, court: 0, sideA: Side(first: kept, second: dropped)),
      GameSpec(round: 0, court: 1, sideA: Side(first: dropped, second: kept)),
    ]) == ssOk
    check setSkips(db, communityId, sessionId, "0-0", 2,
      @[dropped]) == ssOk
    check skips() == @[dropped]
    # The same player stays in 0-1, so only the skip of 0-0 becomes stale.
    check putSchedule(db, communityId, sessionId, 3, @[
      GameSpec(round: 0, court: 0, sideA: Side(first: kept, second: other)),
      GameSpec(round: 0, court: 1, sideA: Side(first: dropped, second: kept)),
    ]) == ssOk
    check skips().len == 0

  test "a missing game answers not found without bumping the version":
    check setScore(db, communityId, sessionId, "0-0", 1, 21, 15) == ssNotFound
    check version() == "1"
    check setPlayed(db, communityId, sessionId, "0-0", 1, true) == ssNotFound
    check version() == "1"

  test "marking players absent is one statement whatever the count":
    var roster: seq[string] = @[]
    for index in 0 ..< 8:
      let playerId = addPlayer("Absent " & $index)
      roster.add(playerId)
      discard db.execUpdate(
        """insert into session.participants (community_id, session_id, player_id)
           values ($1::uuid, $2::uuid, $3::uuid)""",
        @[textParam(communityId), textParam(sessionId), textParam(playerId)])

    # The same four statements every time: the version gate, the participant
    # check, the session bump and one flag update for the whole roster. A tenth
    # player would not add a tenth round trip.
    for ids in [roster[0 ..< 1], roster[0 ..< 4], roster]:
      check setAbsent(db, communityId, sessionId, parseInt(version()),
        ids) == ssOk
      check statementsInTransaction() == 4

    # The update assigns the flag instead of only raising it: a participant the
    # caller leaves out reads as present again, which is what the old
    # reset-then-mark pair wrote.
    check setAbsent(db, communityId, sessionId, parseInt(version()),
      roster[4 ..< 8]) == ssOk
    check statementsInTransaction() == 4
    for index, playerId in roster:
      check absent(playerId) == (index >= 4)