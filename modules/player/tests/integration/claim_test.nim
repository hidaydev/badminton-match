## The claim surface BE-16 names: every `ClaimError` refusal, the pending row a
## submit creates, the decide guards, release, and the two lookups the routes
## use. The module is single-threaded here because `decide` takes an advisory
## lock. Needs MAJADU_PG_DSN.

import std/[options, os, unittest]
import db/db
import tests/fixtures
import ../../claim

const
  slug = "be16-claim"
  unknownId = "11111111-1111-1111-1111-111111111111"

if getEnv("MAJADU_PG_DSN").len == 0:
  raise newException(ValueError, "MAJADU_PG_DSN is required")

proc claimRow(db: Db, communityId, playerId, claimId: string): Option[Row] =
  db.queryOne(
    """select status, user_id::text as user_id,
              coalesce(decided_by::text, '') as decided_by,
              coalesce(reason, '') as reason
       from player.claims
       where community_id = $1::uuid and player_id = $2::uuid and id = $3::uuid""",
    @[textParam(communityId), textParam(playerId), textParam(claimId)])

proc pendingClaimId(db: Db, communityId, playerId: string): string =
  db.queryOne(
    """select id from player.claims
       where community_id = $1::uuid and player_id = $2::uuid
         and status = 'pending'""",
    @[textParam(communityId), textParam(playerId)]).get.get("id")

proc playerUser(db: Db, communityId, playerId: string): Option[string] =
  db.queryOne(
    """select user_id::text as user_id from player.players
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(playerId)]).get.getOpt("user_id")

suite "player claim":
  var db: Db
  var communityId: string
  var admin, filer, third, ownerUser: string

  proc reset() =
    purgeCommunity(db, slug)
    discard db.execUpdate(
      "delete from platform.user where google_sub like 'be16-%'")
    communityId = newCommunity(db, slug, "BE16 Claim")
    admin = newUser(db, "be16-claim-admin", "be16-claim-admin@example.com")
    filer = newUser(db, "be16-claim-filer", "be16-claim-filer@example.com")
    third = newUser(db, "be16-claim-third", "be16-claim-third@example.com")
    ownerUser = newUser(db, "be16-claim-owner",
      "be16-claim-owner@example.com")

  setup:
    db = openDb(getEnv("MAJADU_PG_DSN"), 1)
    reset()

  teardown:
    purgeCommunity(db, slug)
    discard db.execUpdate(
      "delete from platform.user where google_sub like 'be16-%'")
    db.close()

  test "submit refuses the four cases and writes one pending row":
    let target = newPlayer(db, communityId, "Claim Target")
    check submit(db, communityId, unknownId, filer) == cePlayerNotFound

    let boundPlayer = newPlayer(db, communityId, "Bound Player",
      userId = ownerUser)
    check submit(db, communityId, boundPlayer, filer) == ceAlreadyClaimed

    # ownerUser already holds boundPlayer, so it cannot collect a second one.
    let ownedPlayer = newPlayer(db, communityId, "Owned Elsewhere")
    check submit(db, communityId, ownedPlayer, ownerUser) == ceClaimantOwnsPlayer

    check submit(db, communityId, target, filer) == ceOk
    let claimId = pendingClaimId(db, communityId, target)
    let row = claimRow(db, communityId, target, claimId).get
    check row.get("status") == "pending"
    check row.get("user_id") == filer
    check row.get("decided_by") == ""
    check row.get("reason") == ""
    check playerUser(db, communityId, target).isNone

    # The partial unique index keeps one pending claim per player.
    check submit(db, communityId, target, third) == ceAlreadyPending
    check db.queryOne(
      """select count(*)::int as n from player.claims
         where community_id = $1::uuid and player_id = $2::uuid""",
      @[textParam(communityId), textParam(target)]).get.get("n") == "1"

  test "decide guards an unknown claim, a self decision and a second decision":
    let target = newPlayer(db, communityId, "Decide Target")
    check decide(db, communityId, target, unknownId, admin, true, "") ==
      ceClaimNotFound

    # The admin who filed the claim cannot decide it, and nothing is written.
    check submit(db, communityId, target, admin) == ceOk
    let selfClaim = pendingClaimId(db, communityId, target)
    check decide(db, communityId, target, selfClaim, admin, true, "") ==
      ceSelfDecision
    var row = claimRow(db, communityId, target, selfClaim).get
    check row.get("status") == "pending"
    check row.get("decided_by") == ""
    check playerUser(db, communityId, target).isNone

    # A different admin approves: the player binds and the row records both.
    check decide(db, communityId, target, selfClaim, filer, true, "met at court") ==
      ceOk
    row = claimRow(db, communityId, target, selfClaim).get
    check row.get("status") == "approved"
    check row.get("decided_by") == filer
    check row.get("reason") == "met at court"
    check playerUser(db, communityId, target) == some(admin)

    # The `status = 'pending'` predicate makes a second decision a conflict.
    check decide(db, communityId, target, selfClaim, filer, false, "") ==
      ceConflict
    row = claimRow(db, communityId, target, selfClaim).get
    check row.get("status") == "approved"
    check row.get("decided_by") == filer

  test "a rejection records the decision and leaves the player unbound":
    let target = newPlayer(db, communityId, "Reject Target")
    check submit(db, communityId, target, filer) == ceOk
    let claimId = pendingClaimId(db, communityId, target)
    check decide(db, communityId, target, claimId, admin, false, "") == ceOk
    let row = claimRow(db, communityId, target, claimId).get
    check row.get("status") == "rejected"
    check row.get("decided_by") == admin
    check row.get("reason") == "rejected"
    check playerUser(db, communityId, target).isNone

  test "release refuses an unknown and a not approved claim, then releases":
    let pendingPlayer = newPlayer(db, communityId, "Pending Release")
    check submit(db, communityId, pendingPlayer, third) == ceOk
    let pendingClaim = pendingClaimId(db, communityId, pendingPlayer)
    check release(db, communityId, pendingPlayer, admin, unknownId, third, "") ==
      ceConflict
    check release(db, communityId, pendingPlayer, admin, pendingClaim, third,
      "not approved") == ceConflict
    var row = claimRow(db, communityId, pendingPlayer, pendingClaim).get
    check row.get("status") == "pending"
    check row.get("decided_by") == ""

    let target = newPlayer(db, communityId, "Release Target")
    check submit(db, communityId, target, ownerUser) == ceOk
    let claimId = pendingClaimId(db, communityId, target)
    check decide(db, communityId, target, claimId, admin, true, "") == ceOk
    # Both lookups name the claimant that the approval bound.
    check claimOwner(db, communityId, target, claimId) == ownerUser
    check approvedClaimFor(db, communityId, target, ownerUser) == claimId
    check playerUser(db, communityId, target) == some(ownerUser)

    check release(db, communityId, target, admin, claimId, ownerUser,
      "account transfer") == ceOk
    row = claimRow(db, communityId, target, claimId).get
    check row.get("status") == "released"
    check row.get("decided_by") == admin
    check row.get("reason") == "account transfer"
    check claimOwner(db, communityId, target, claimId) == ownerUser
    check approvedClaimFor(db, communityId, target, ownerUser) == ""
    check playerUser(db, communityId, target).isNone

  test "list returns one player's trail newest first with its reasons":
    let target = newPlayer(db, communityId, "List Target")
    let other = newPlayer(db, communityId, "Other List Target")
    check submit(db, communityId, target, filer) == ceOk
    let firstClaim = pendingClaimId(db, communityId, target)
    check decide(db, communityId, target, firstClaim, admin, false,
      "not verified") == ceOk
    discard db.execUpdate(
      """update player.claims set created_at = now() - interval '1 hour'
         where community_id = $1::uuid and id = $2::uuid""",
      @[textParam(communityId), textParam(firstClaim)])
    check submit(db, communityId, target, third) == ceOk
    let secondClaim = pendingClaimId(db, communityId, target)
    check submit(db, communityId, other, filer) == ceOk

    let trail = list(db, communityId, target, 100, 0)
    check trail.len == 2
    check trail[0].id == secondClaim
    check trail[0].status == "pending"
    check trail[0].userId == third
    check trail[1].id == firstClaim
    check trail[1].status == "rejected"
    check trail[1].reason == "not verified"
    # The other player's claim is not part of this trail.
    for entry in trail:
      check entry.id != pendingClaimId(db, communityId, other)