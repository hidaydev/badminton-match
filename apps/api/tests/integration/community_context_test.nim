import std/[options, os, unittest]
import db/db
import account/domain/roles
import community/tenancy
import session/application/detail as sessionDetail
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

  test "a second community in one database stays separate and is refused at boot":
    # DB-16 option (c): the door is per community, a scoped read refuses the
    # other community's row, and a production boot refuses the database that
    # holds both. Development and test databases keep many communities, which
    # the rule module covers without a database.
    let otherId = newCommunity(db, "ctx-other", "Context Other")
    let sessionA = db.queryOne(
      """insert into session.sessions
           (community_id, title, session_date, status, source)
         values ($1::uuid, 'A night', '2026-11-01', 'draft', 'manual')
         returning id""",
      @[textParam(communityId)]).get.get("id")

    check communityCount(db) >= 2
    check sessionDetail.exists(db, communityId, sessionA)
    check not sessionDetail.exists(db, otherId, sessionA)
    check loadCommunity(db, memberId, "ctx-other").isNone
    check singleCommunityViolation(communityCount(db), "prod").len > 0
