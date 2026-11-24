## The three definer functions, resolved by the bytes they compare against.
##
## `session.share_link_resolve` takes the SHA-256 of the code as `bytea`. Passed
## as the hex string the code path already had (`textParam(sha256Hex(code))`),
## libpq sends it untyped, the server resolves it to the `bytea` overload, and
## the value arrives as 64 ASCII characters instead of 32 bytes:
##
##   select length('e3b0c4...'::bytea), length(decode('e3b0c4...','hex')) -> 64 | 32
##
## So `code_hash = $1` never matches, `resolve` returns none, and every live
## share link in every group chat answers 404 "link not found". This suite is the
## proof, and it is why the fix is `byteaParam(sha256Raw(code))` rather than a
## cast: the comparison is on bytes, so the parameter has to be bytes.
##
## The other two are here because the same question has to be asked of each:
##
##   - `community.invite_by_token` already wraps the parameter in
##     `decode($1,'hex')`, so its text parameter is correct and the round trip
##     proves the invite still resolves through the function.
##   - `community.membership_context` takes `(text, uuid)`, no bytes at all, so
##     the round trip proves the definer path answers for the pre-context door
##     without needing the bytea parameter.
##
## Every case runs as `bm2_app` with no tenant installed: under the policy set a
## plain read returns nothing, so only the definer function can answer. On a
## database without the policies the plain path answers and the whole file is
## vacuous, which is why the precondition is an assertion.

import std/[options, os, unittest]
import db/db
import sha256
import account/domain/roles
import community/infrastructure/invite
import share/crypto
import share/store
import tests/fixtures
import tests/app_role_fixture
import ../../src/community_context

const
  keysJson = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"""
  slugA = "policy-bytea-a"
  slugB = "policy-bytea-b"

proc dsn(): string = getEnv("MAJADU_PG_DSN")

suite "definer functions under the policy set":
  var db: Db
  var keyring: Keyring
  var communityA, communityB, hostId, memberId: string
  var sessionA, sessionB: string

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    let policies = db.queryOne(
      """select count(*)::int as n from pg_policies
         where schemaname in ('session', 'community')""").get.getInt("n")
    doAssert policies > 0, "policy_definer_bytea needs the 0061 policy set; " &
      "run it in the job that applies 0061 (./task policy-test)"
    for slug in [slugA, slugB]:
      purgeCommunity(db, slug)
    discard db.execUpdate(
      "delete from platform.user where google_sub like 'policy-bytea-%'")
    keyring = loadKeyring(keysJson, "1")
    communityA = newCommunity(db, slugA, "Policy Bytea A")
    communityB = newCommunity(db, slugB, "Policy Bytea B")
    hostId = newUser(db, "policy-bytea-host", "policy-bytea-host@example.com")
    memberId = newUser(db, "policy-bytea-member", "policy-bytea-member@example.com")
    newMember(db, communityA, hostId, "admin")
    newMember(db, communityA, memberId, "member")
    sessionA = newSession(db, communityA, "Bytea A", status = "locked")
    sessionB = newSession(db, communityB, "Bytea B", status = "locked")

  teardown:
    for slug in [slugA, slugB]:
      purgeCommunity(db, slug)
    discard db.execUpdate(
      "delete from platform.user where google_sub like 'policy-bytea-%'")
    db.close()

  test "a share link resolves by its code bytes":
    let code = issue(db, keyring, communityA, sessionA, hostId, 30)
    check code.len == 32
    var found = none(ShareLookup)
    asApp(db, proc(app: Db, conn: DbConn) =
      found = resolve(app, keyring, code))
    # On the text parameter this is `none` and the route answers "link not
    # found": the row exists, the hash is right, and 64 characters never equal
    # the 32-byte column.
    check found.isSome
    check found.get.sessionId == sessionA
    check found.get.slug == slugA

  test "an invitation resolves by its token":
    let token = invite.create(db, communityA,
      sha256Hex("policy-bytea-invitee@example.com"), rMember, hostId, 7)
    var found = AcceptResult(outcome: aoNotFound)
    asApp(db, proc(app: Db, conn: DbConn) =
      found = invite.lookup(app, token))
    check found.outcome in {aoOk, aoUsed}
    check found.communityId == communityA

  test "the community context resolves for a member and not for a stranger":
    var member, stranger = none(CommunityContext)
    var unknown = none(CommunityContext)
    asApp(db, proc(app: Db, conn: DbConn) =
      member = loadCommunity(app, memberId, slugA)
      stranger = loadCommunity(app, hostId, slugB)
      unknown = loadCommunity(app, memberId, "policy-bytea-absent"))
    check member.isSome
    check member.get.communityId == communityA
    check member.get.role == rMember
    # A community this user is not a member of answers exactly like one that
    # does not exist.
    check stranger.isNone
    check unknown.isNone

  test "the raw hash is 32 bytes, which is what the column holds":
    # The comparison the fix turns on, asked of the database so the suite fails
    # on the fact rather than on a fixture's guess.
    let code = "policy-bytea-code"
    let row = db.queryOne(
      """select length($1::bytea) as as_text,
                length($2::bytea) as as_bytes,
                $1::bytea = $2::bytea as equal""",
      @[textParam(sha256Hex(code)), byteaParam(sha256Raw(code))]).get
    check row.getInt("as_text") == 64
    check row.getInt("as_bytes") == 32
    check not row.getBool("equal")
