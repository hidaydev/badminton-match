import std/[options, os, unittest]
import db/db
import account/domain/roles
import ../../src/community_context

proc dsn(): string = getEnv("MAJADU_PG_DSN")

suite "community context":
  var db: Db
  var memberId, strangerId, communityId: string

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    discard db.execUpdate(
      "delete from platform.community where slug in ('ctx-test', 'ctx-other')")
    discard db.execUpdate(
      "delete from platform.user where google_sub like 'ctx-test-%'")
    memberId = db.queryOne(
      """insert into platform.user (google_sub, email_hash, display_name)
         values ('ctx-test-member', 'ctx-hash-1', 'Member') returning id""").get.get("id")
    strangerId = db.queryOne(
      """insert into platform.user (google_sub, email_hash, display_name)
         values ('ctx-test-stranger', 'ctx-hash-2', 'Stranger') returning id""").get.get("id")
    communityId = db.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ('ctx-test', 'Context Test', 'Asia/Jakarta') returning id""").get.get("id")
    discard db.execUpdate(
      """insert into community.membership (community_id, user_id, role)
         values ($1::uuid, $2::uuid, 'host')""",
      @[textParam(communityId), textParam(memberId)])

  teardown:
    db.close()

  test "member resolves the community and its role":
    let resolved = loadCommunity(db, memberId, "ctx-test")
    check resolved.isSome
    check resolved.get.communityId == communityId
    check resolved.get.role == rHost

  test "a non-member sees nothing":
    check loadCommunity(db, strangerId, "ctx-test").isNone

  test "an unknown slug sees nothing":
    check loadCommunity(db, memberId, "ctx-missing").isNone
