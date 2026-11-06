import std/[options, os, sequtils, unittest]
import db/db
import sha256
import ../../domain/community
import ../../infrastructure/[community_store, invite, join_request, membership]

proc dsn(): string = getEnv("MAJADU_PG_DSN")

suite "community access":
  var db: Db
  var communityId, adminId, outsiderId: string
  let adminEmail = "admin@example.com"
  let outsiderEmail = "member@example.com"

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    discard db.execUpdate("delete from platform.community where slug = 'access-test'")
    discard db.execUpdate("delete from platform.user where google_sub like 'access-%'")
    adminId = db.queryOne(
      """insert into platform.user (google_sub, email_hash, display_name)
         values ('access-admin', $1, 'Admin') returning id""",
      @[textParam(sha256Hex(adminEmail))]).get.get("id")
    outsiderId = db.queryOne(
      """insert into platform.user (google_sub, email_hash, display_name)
         values ('access-member', $1, 'Member') returning id""",
      @[textParam(sha256Hex(outsiderEmail))]).get.get("id")
    communityId = community_store.create(db, "access-test", "Access Test", adminEmail,
      "Asia/Jakarta", adminId).communityId

  teardown:
    db.close()

  test "the first admin invitation binds to the address":
    let invite = db.queryOne(
      """select email_hash from community.invite where community_id = $1::uuid""",
      @[textParam(communityId)]).get
    check invite.get("email_hash") == sha256Hex(adminEmail)

  test "an invitation grants the address once and stays idempotent for it":
    let token = invite.create(db, communityId, sha256Hex(outsiderEmail), "host",
      adminId, 7)
    let first = invite.accept(db, token, outsiderId, sha256Hex(outsiderEmail))
    check first.outcome == aoOk
    check first.role == "host"
    # Login auto-accepts invites, so the recipient may click the link after the
    # grant already happened; that must report the membership, not "used".
    let second = invite.accept(db, token, outsiderId, sha256Hex(outsiderEmail))
    check second.outcome == aoOk
    check second.communityId == first.communityId
    check second.role == "host"
    check membership.list(db, communityId).anyIt(it.userId == outsiderId and it.role == "host")

  test "login auto-accept reports only the memberships it created":
    # The first-admin invite is pending for this address at first login.
    let first = invite.acceptPendingForEmail(db, adminId, sha256Hex(adminEmail))
    check first.len == 1
    check first[0].communityId == communityId
    check first[0].role == "admin"
    # The invite is redeemed and the membership now exists: a second run must
    # not report the grant again, or the caller would audit a no-op.
    check invite.acceptPendingForEmail(db, adminId, sha256Hex(adminEmail)).len == 0
    discard invite.create(db, communityId, sha256Hex(adminEmail), "host", adminId, 7)
    check invite.acceptPendingForEmail(db, adminId, sha256Hex(adminEmail)).len == 0

  test "a different address cannot redeem the invitation":
    let token = invite.create(db, communityId, sha256Hex(outsiderEmail), "member",
      adminId, 7)
    let wrong = invite.accept(db, token, adminId, sha256Hex(adminEmail))
    check wrong.outcome == aoEmailMismatch
    let right = invite.accept(db, token, outsiderId, sha256Hex(outsiderEmail))
    check right.outcome == aoOk

  test "an expired invitation is refused":
    let token = invite.create(db, communityId, sha256Hex(outsiderEmail), "member",
      adminId, 7)
    discard db.execUpdate(
      """update community.invite set expires_at = now() - interval '1 minute'
         where community_id = $1::uuid""", @[textParam(communityId)])
    check invite.accept(db, token, outsiderId, sha256Hex(outsiderEmail)).outcome == aoExpired

  test "an unknown token is not found":
    check invite.accept(db, "deadbeef", outsiderId, sha256Hex(outsiderEmail)).outcome ==
      aoNotFound

  test "join requests are idempotent while pending":
    check join_request.request(db, communityId, outsiderId)
    # The second call is a no-op, and says so instead of reporting a write.
    check not join_request.request(db, communityId, outsiderId)
    check join_request.listPending(db, communityId).len == 1

  test "approving a request adds the member and cannot be repeated":
    discard join_request.request(db, communityId, outsiderId)
    let pending = join_request.listPending(db, communityId)[0]
    check join_request.decide(db, communityId, pending.id, adminId, "member", true)
    check not join_request.decide(db, communityId, pending.id, adminId, "member", true)
    check membership.list(db, communityId).anyIt(it.userId == outsiderId and it.role == "member")
    check join_request.listPending(db, communityId).len == 0

  test "rejecting a request does not add a member":
    discard join_request.request(db, communityId, outsiderId)
    let pending = join_request.listPending(db, communityId)[0]
    check join_request.decide(db, communityId, pending.id, adminId, "member", false)
    check not list(db, communityId).anyIt(it.userId == outsiderId)

  test "changing and removing a role is reported":
    discard membership.add(db, communityId, outsiderId, "member")
    check membership.setRole(db, communityId, outsiderId, "host")
    check not membership.setRole(db, communityId, "11111111-1111-1111-1111-111111111111", "host")
    check membership.remove(db, communityId, outsiderId)
    check not membership.remove(db, communityId, outsiderId)

  test "a guarded role change names why it was refused":
    discard membership.add(db, communityId, outsiderId, "member")
    discard membership.add(db, communityId, adminId, "admin")
    check membership.setRoleChecked(db, communityId, outsiderId, "host") == mwOk
    check membership.list(db, communityId).anyIt(it.userId == outsiderId and it.role == "host")
    check membership.setRoleChecked(db, communityId,
      "11111111-1111-1111-1111-111111111111", "host") == mwNotFound
    # The only admin cannot be demoted, and re-setting the same role is allowed.
    check membership.setRoleChecked(db, communityId, adminId, "member") == mwLastAdmin
    check membership.setRoleChecked(db, communityId, adminId, "admin") == mwOk
    check membership.removeChecked(db, communityId, adminId) == mwLastAdmin
    check membership.removeChecked(db, communityId, outsiderId) == mwOk
    check membership.removeChecked(db, communityId, outsiderId) == mwNotFound
