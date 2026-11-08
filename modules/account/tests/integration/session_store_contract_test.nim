## The session store contract the existing suite does not name: only a hash is
## stored, an empty token never reaches the database, and the list is ordered by
## last use. The existing suite owns expiry and revocation; this one owns the
## storage shape.

import std/[options, os, unittest]
import db/db
import sha256
import tests/fixtures
import ../../infrastructure/session_store

suite "session store storage":
  var db: Db
  var userId: string
  var fixtureNo = 0

  setup:
    if getEnv("MAJADU_PG_DSN").len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(getEnv("MAJADU_PG_DSN"), 1)
    inc fixtureNo
    let suffix = $getCurrentProcessId() & "-" & $fixtureNo
    userId = newUser(db, "be12-session-" & suffix,
      "be12-session-" & suffix & "@example.com", "Session fixture")

  teardown:
    if db != nil:
      discard db.execUpdate(
        "delete from account.sessions where user_id = $1::uuid",
        @[textParam(userId)])
      discard db.execUpdate("delete from platform.user where id = $1::uuid",
        @[textParam(userId)])
      db.close()

  test "createSession stores only the sha256 of the cookie value":
    let token = createSession(db, userId, 30)
    let row = db.queryOne(
      """select encode(token_hash, 'hex') as token_hash
         from account.sessions where user_id = $1::uuid""",
      @[textParam(userId)]).get
    check row.get("token_hash") == sha256Hex(token)
    check row.get("token_hash") != token
    # A one-character change is a different hash, so the session does not
    # resolve; the stored copy is not the raw value with a prefix.
    var changed = token
    changed[0] = if changed[0] == 'a': 'b' else: 'a'
    check resolve(db, changed, 7).isNone
    check resolve(db, token, 7).isSome

  test "resolve of an empty token returns none":
    discard createSession(db, userId, 30)
    check resolve(db, "", 7).isNone

  test "listSessions orders by last_seen_at, newest first":
    let oldest = createSession(db, userId, 30)
    let middle = createSession(db, userId, 30)
    let newest = createSession(db, userId, 30)
    let oldestId = db.queryOne(
      """select id from account.sessions where token_hash = decode($1, 'hex')""",
      @[textParam(sha256Hex(oldest))]).get.getUuid("id")
    let middleId = db.queryOne(
      """select id from account.sessions where token_hash = decode($1, 'hex')""",
      @[textParam(sha256Hex(middle))]).get.getUuid("id")
    let newestId = db.queryOne(
      """select id from account.sessions where token_hash = decode($1, 'hex')""",
      @[textParam(sha256Hex(newest))]).get.getUuid("id")
    discard db.execUpdate(
      """update account.sessions set last_seen_at = now() - interval '3 hours'
         where id = $1::uuid""", @[textParam(oldestId)])
    discard db.execUpdate(
      """update account.sessions set last_seen_at = now() - interval '2 hours'
         where id = $1::uuid""", @[textParam(middleId)])
    discard db.execUpdate(
      """update account.sessions set last_seen_at = now() - interval '1 hour'
         where id = $1::uuid""", @[textParam(newestId)])
    let ordered = listSessions(db, userId, middle)
    check ordered.len == 3
    check ordered[0].id == newestId
    check ordered[1].id == middleId
    check ordered[2].id == oldestId
    check ordered[1].current