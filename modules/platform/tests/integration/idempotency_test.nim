import std/[json, options, os, sequtils, unittest]
import db/db
import ../../idempotency

proc dsn(): string = getEnv("MAJADU_PG_DSN")

type
  ClaimJob = object
    dsn, userId, key, digest: string
    status: IdempotencyStatus

proc claimInThread(job: ptr ClaimJob) {.thread.} =
  {.cast(gcsafe).}:
    var db = openDb(job.dsn, 1)
    try:
      job.status = claim(db, job.userId, job.key, job.digest).status
    finally:
      db.close()

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

  test "an in-flight claim is a conflict, not a crash":
    let key = scopedKey("c1", "in-flight")
    let digest = bodyHash("""{"a":1}""")
    check claim(db, userId, key, digest).status == idempotencyNew
    check claim(db, userId, key, digest).status == idempotencyConflict

  test "an expired key is replaced and replays the new response":
    let key = scopedKey("c1", "expired")
    let oldDigest = bodyHash("""{"a":1}""")
    let newDigest = bodyHash("""{"a":2}""")
    discard claim(db, userId, key, oldDigest)
    complete(db, userId, key, 201, %*{"id": "old"})
    discard db.execUpdate(
      "update platform.idempotency_keys set expires_at = now() - interval '1 hour' where key = $1",
      @[textParam(key)])

    check claim(db, userId, key, newDigest).status == idempotencyNew
    complete(db, userId, key, 202, %*{"id": "new"})
    let replay = claim(db, userId, key, newDigest)
    check replay.status == idempotencyReplay
    check replay.statusCode == 202
    check replay.response["id"].getStr() == "new"

    let stored = db.queryOne(
      """select body_hash, expires_at > now() as live
         from platform.idempotency_keys where user_id = $1::uuid and key = $2""",
      @[textParam(userId), textParam(key)]).get
    check stored.get("body_hash") == newDigest
    check stored.get("live") == "t"

  test "two parallel claims let exactly one through":
    let key = scopedKey("c1", "parallel")
    let digest = bodyHash("""{"a":1}""")
    var first = ClaimJob(dsn: dsn(), userId: userId, key: key, digest: digest)
    var second = ClaimJob(dsn: dsn(), userId: userId, key: key, digest: digest)
    var firstThread: Thread[ptr ClaimJob]
    var secondThread: Thread[ptr ClaimJob]
    createThread(firstThread, claimInThread, addr first)
    createThread(secondThread, claimInThread, addr second)
    joinThread(firstThread)
    joinThread(secondThread)
    check @[first.status, second.status].count(idempotencyNew) == 1
