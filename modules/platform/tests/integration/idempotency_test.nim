import std/[json, options, os, unittest]
import db/db
import ../../idempotency

proc dsn(): string = getEnv("MAJADU_PG_DSN")

suite "idempotency":
  var db: Db
  var userId: string

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    discard db.execUpdate(
      "delete from platform.idempotency_keys where user_id in (select id from platform.user where google_sub = 'idem-test')")
    discard db.execUpdate("delete from platform.user where google_sub = 'idem-test'")
    userId = db.queryOne(
      """insert into platform.user (google_sub, email_hash, display_name)
         values ('idem-test', 'idem-hash', 'Idem') returning id""").get.get("id")

  teardown:
    db.close()

  test "a new key is claimable once":
    let key = scopedKey("c1", "abc")
    check claim(db, userId, key, bodyHash("""{"a":1}""")).status == idempotencyNew

  test "the same key and body replays the stored response":
    let key = scopedKey("c1", "replay")
    let digest = bodyHash("""{"a":1}""")
    discard claim(db, userId, key, digest)
    complete(db, userId, key, 201, %*{"id": "s1"})
    let replay = claim(db, userId, key, digest)
    check replay.status == idempotencyReplay
    check replay.statusCode == 201
    check replay.response["id"].getStr() == "s1"

  test "the same key with a different body is a conflict":
    let key = scopedKey("c1", "conflict")
    discard claim(db, userId, key, bodyHash("""{"a":1}"""))
    complete(db, userId, key, 201, %*{"id": "s2"})
    check claim(db, userId, key, bodyHash("""{"a":2}""")).status == idempotencyConflict

  test "keys are scoped per community":
    let digest = bodyHash("""{"a":1}""")
    check claim(db, userId, scopedKey("c1", "same"), digest).status == idempotencyNew
    check claim(db, userId, scopedKey("c2", "same"), digest).status == idempotencyNew

  test "an expired key can be claimed again":
    let key = scopedKey("c1", "expired")
    discard claim(db, userId, key, bodyHash("""{"a":1}"""))
    discard db.execUpdate(
      "update platform.idempotency_keys set expires_at = now() - interval '1 hour' where key = $1",
      @[textParam(key)])
    check claim(db, userId, key, bodyHash("""{"a":2}""")).status == idempotencyNew
