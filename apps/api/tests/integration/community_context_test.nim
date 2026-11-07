import std/[options, os, unittest]
import db/db
import account/domain/roles
import tests/fixtures
import ../../src/community_context

proc dsn(): string = getEnv("MAJADU_PG_DSN")

suite "community context":
  var db: Db
  var memberId, strangerId, communityId: string

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    for slug in ["ctx-test", "ctx-other"]:
      purgeCommunity(db, slug)
    discard db.execUpdate(
      "delete from platform.user where google_sub like 'ctx-test-%'")
    memberId = newUser(db, "ctx-test-member", "ctx-hash-1", "Member")
    strangerId = newUser(db, "ctx-test-stranger", "ctx-hash-2", "Stranger")
    communityId = newCommunity(db, "ctx-test", "Context Test")
    newMember(db, communityId, memberId, "host")

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
