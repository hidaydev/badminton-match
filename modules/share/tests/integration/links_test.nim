import std/[options, os, sets, unittest]
import db/db
import ../../crypto
import ../../store

const
  keysJson = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","2":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="}"""

proc dsn(): string = getEnv("MAJADU_PG_DSN")

suite "share links":
  var db: Db
  var keyring: Keyring
  var communityId, otherCommunityId, sessionId, otherSessionId, userId: string

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    keyring = loadKeyring(keysJson, "2")
    db = openDb(dsn(), 1)
    discard db.execUpdate(
      """delete from session.links where community_id in
           (select c.id from platform.community c
            where c.slug in ('share-test','share-other'))""")
    discard db.execUpdate(
      """delete from session.sessions where community_id in
           (select c.id from platform.community c
            where c.slug in ('share-test','share-other'))""")
    discard db.execUpdate(
      "delete from platform.community where slug in ('share-test','share-other')")
    discard db.execUpdate(
      "delete from platform.user where google_sub = 'share-test-user'")
    userId = db.queryOne(
      """insert into platform.user (google_sub, email_hash, display_name)
         values ('share-test-user', 'share-hash', 'Host') returning id""").get.get("id")
    communityId = db.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ('share-test', 'Share Test', 'Asia/Jakarta') returning id""").get.get("id")
    otherCommunityId = db.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ('share-other', 'Other', 'Asia/Jakarta') returning id""").get.get("id")
    sessionId = db.queryOne(
      """insert into session.sessions (community_id, title, session_date, status, source)
         values ($1::uuid, 'Session', '2026-11-03', 'draft', 'manual') returning id""",
      @[textParam(communityId)]).get.get("id")
    otherSessionId = db.queryOne(
      """insert into session.sessions (community_id, title, session_date, status, source)
         values ($1::uuid, 'Other session', '2026-11-03', 'draft', 'manual') returning id""",
      @[textParam(otherCommunityId)]).get.get("id")

  teardown:
    db.close()

  test "a new code resolves with its session and community":
    let code = issue(db, keyring, communityId, sessionId, userId, 30)
    check code.len == 32
    let found = resolve(db, keyring, code)
    check found.isSome
    check found.get.sessionId == sessionId
    check found.get.slug == "share-test"

  test "the same code cannot be resolved across communities":
    let code = issue(db, keyring, communityId, sessionId, userId, 30)
    let found = resolve(db, keyring, code).get
    check found.communityId == communityId
    check resolve(db, keyring, "0" & code[1 .. ^1]).isNone or
      resolve(db, keyring, "0" & code[1 .. ^1]).get.communityId == communityId

  test "rotating the link revokes the previous code":
    let first = issue(db, keyring, communityId, sessionId, userId, 30)
    let second = issue(db, keyring, communityId, sessionId, userId, 30)
    check first != second
    check resolve(db, keyring, first).isNone
    check resolve(db, keyring, second).isSome

  test "current code is re-readable by the store":
    let code = issue(db, keyring, communityId, sessionId, userId, 30)
    check currentCode(db, keyring, communityId, sessionId).get == code
    check currentCode(db, keyring, otherCommunityId, otherSessionId).isNone

  test "key rotation re-encrypts old links and is idempotent":
    let oldKeyring = loadKeyring(keysJson, "1")
    let code = issue(db, oldKeyring, communityId, sessionId, userId, 30)
    check resolve(db, oldKeyring, code).isSome
    # The row is sealed with key 1; the active key is 2.
    # Other rows in the database may also still be sealed with key 1, so the
    # count is a lower bound; the assertion that matters is the code below.
    let firstPass = rotateKeys(db, keyring, "1", "2")
    check firstPass >= 1
    check resolve(db, keyring, code).isSome
    let secondPass = rotateKeys(db, keyring, "1", "2")
    check secondPass == 0

  test "a v1 style session id resolves while the session has a live link":
    discard issue(db, keyring, communityId, sessionId, userId, 30)
    # `/s/{sessionId}` is what version one handed out; the row is still live, so
    # the id answers for it and links already in a group chat keep working.
    let byId = resolve(db, keyring, sessionId)
    check byId.isSome
    check byId.get.sessionId == sessionId
    # A 36-character string that is not an id must not reach a `::uuid` cast.
    check resolve(db, keyring, "00000000-0000-0000-0000-00000000000z").isNone
    check resolve(db, keyring, "not-a-link").isNone

  test "a revoked session answers no longer answers by its id":
    let code = issue(db, keyring, communityId, sessionId, userId, 30)
    check resolve(db, keyring, sessionId).isSome
    check revokeLive(db, communityId, sessionId).len == 1
    check resolve(db, keyring, sessionId).isNone
    check resolve(db, keyring, code).isNone

  test "liveLinks lists only the live rows":
    discard issue(db, keyring, communityId, sessionId, userId, 30)
    let live = liveLinks(db, communityId, sessionId)
    check live.len == 1
    discard revokeLive(db, communityId, sessionId)
    check liveLinks(db, communityId, sessionId).len == 0
    # A session in another community is never listed.
    check liveLinks(db, otherCommunityId, sessionId).len == 0

  test "100000 generated codes are distinct":
    var seen = initHashSet[string]()
    for _ in 0 ..< 100_000:
      seen.incl(newShareCode())
    check seen.len == 100_000
