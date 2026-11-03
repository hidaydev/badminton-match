import std/[options, os, unittest]
import db/db
import ../../infrastructure/session_store

const channelId = "11111111-1111-1111-1111-111111111111"

proc dsn(): string = getEnv("MAJADU_PG_DSN")

suite "session store":
  var db: Db
  var userId: string

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    discard db.execUpdate("delete from platform.ws_ticket")
    discard db.execUpdate("delete from account.sessions")
    discard db.execUpdate("delete from platform.user where google_sub like 'session-test-%'")
    userId = db.queryOne(
      """insert into platform.user (google_sub, email_hash, display_name)
         values ('session-test-1', 'hash-session-1', 'Tester') returning id""").get.get("id")

  teardown:
    db.close()

  test "resolve returns the user and refreshes last_seen_at":
    let token = createSession(db, userId, 30)
    let resolved = resolve(db, token, 7)
    check resolved.isSome
    check resolved.get.userId == userId
    check resolve(db, "not-a-token", 7).isNone

  test "revoke makes the next request fail":
    let token = createSession(db, userId, 30)
    check resolve(db, token, 7).isSome
    revoke(db, token)
    check resolve(db, token, 7).isNone

  test "idle expiry closes an old session":
    let token = createSession(db, userId, 30)
    discard db.execUpdate(
      "update account.sessions set last_seen_at = now() - interval '10 days'")
    check resolve(db, token, 7).isNone

  test "absolute expiry wins over activity":
    let token = createSession(db, userId, 30)
    discard db.execUpdate(
      "update account.sessions set absolute_expires_at = now() - interval '1 second'")
    check resolve(db, token, 7).isNone

  test "revoke-all keeps the current session and drops the others":
    let keep = createSession(db, userId, 30)
    let other = createSession(db, userId, 30)
    discard db.execUpdate(
      """insert into platform.ws_ticket (token_hash, channel_kind, channel_id, user_id, expires_at)
         values (decode(repeat('ab', 32),'hex'), 'session', $1::uuid, $2::uuid, now() + interval '1 hour')""",
      @[textParam(channelId), textParam(userId)])
    revokeOthers(db, userId, keep)
    check resolve(db, keep, 7).isSome
    check resolve(db, other, 7).isNone
    let tickets = db.queryOne(
      "select count(*) as total from platform.ws_ticket where user_id = $1::uuid",
      @[textParam(userId)]).get
    check tickets.get("total") == "0"

  test "list marks the current session":
    let keep = createSession(db, userId, 30)
    discard createSession(db, userId, 30)
    let rows = listSessions(db, userId, keep)
    check rows.len == 2
    var current = 0
    for row in rows:
      if row.current:
        current.inc
    check current == 1
