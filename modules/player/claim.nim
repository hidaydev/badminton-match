import std/[options, strutils]
import db/db
import ./store

type
  ClaimError* = enum
    ceOk = "ok"
    cePlayerNotFound = "player_not_found"
    ceAlreadyPending = "already_pending"
    ceAlreadyClaimed = "already_claimed"
    ceClaimantOwnsPlayer = "claimant_owns_player"
    ceClaimNotFound = "claim_not_found"
    ceSelfDecision = "self_decision"
    ceConflict = "conflict"

  Claim* = object
    id*: string
    userId*: string
    status*: string
    decidedBy*: string
    decidedAt*: string
    reason*: string
    createdAt*: string

  PendingClaim* = object
    claimId*: string
    playerId*: string
    playerName*: string
    userId*: string
    displayName*: string
    createdAt*: string

proc ownsPlayer*(db: Db, communityId, userId: string): bool =
  ## One player per account per community (D11), so an owner cannot collect more.
  let owned = db.queryOne(
    """select 1 as found from player.players
       where community_id = $1::uuid and user_id = $2::uuid limit 1""",
    @[textParam(communityId), textParam(userId)])
  owned.isSome

proc submit*(db: Db, communityId, playerId, userId: string): ClaimError =
  ## A claim never binds on its own: this only creates a pending row. The
  ## partial unique index makes a second pending claim a no-op.
  let player = db.queryOne(
    """select user_id from player.players
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(playerId)])
  if player.isNone:
    return cePlayerNotFound
  if not player.get["user_id"].isNone:
    return ceAlreadyClaimed
  if ownsPlayer(db, communityId, userId):
    return ceClaimantOwnsPlayer
  let inserted = db.execUpdate(
    """insert into player.claims (community_id, player_id, user_id)
       values ($1::uuid, $2::uuid, $3::uuid)
       on conflict do nothing""",
    @[textParam(communityId), textParam(playerId), textParam(userId)])
  if inserted == 0: ceAlreadyPending else: ceOk

proc list*(db: Db, communityId, playerId: string): seq[Claim] =
  for row in db.query(
    """select id, user_id, status, coalesce(decided_by::text, '') as decided_by,
              coalesce(decided_at::text, '') as decided_at,
              coalesce(reason, '') as reason, created_at::text as created_at
       from player.claims
       where community_id = $1::uuid and player_id = $2::uuid
       order by created_at desc""",
    @[textParam(communityId), textParam(playerId)]):
    result.add(Claim(id: row.get("id"), userId: row.get("user_id"),
      status: row.get("status"), decidedBy: row.get("decided_by"),
      decidedAt: row.get("decided_at"), reason: row.get("reason"),
      createdAt: row.get("created_at")))

proc listPending*(db: Db, communityId: string): seq[PendingClaim] =
  ## A pending claim is only visible on its player's page; this queue is the
  ## one place an admin can discover it without knowing the player already.
  for row in db.query(
    """select cl.id, cl.player_id, p.canonical_name, cl.user_id, u.display_name,
              cl.created_at::text as created_at
       from player.claims cl
       join player.players p
         on p.community_id = cl.community_id and p.id = cl.player_id
       join platform.user u on u.id = cl.user_id
       where cl.community_id = $1::uuid and cl.status = 'pending'
       order by cl.created_at asc""",
    @[textParam(communityId)]):
    result.add(PendingClaim(claimId: row.get("id"),
      playerId: row.get("player_id"), playerName: row.get("canonical_name"),
      userId: row.get("user_id"), displayName: row.get("display_name"),
      createdAt: row.get("created_at")))

proc decide*(db: Db, communityId, playerId, claimId, adminId: string,
             approve: bool, reason: string): ClaimError =
  ## Approval fills `user_id` and closes every other pending claim. The admin
  ## who filed the claim cannot decide it, even when they are the only admin.
  let claim = db.queryOne(
    """select user_id from player.claims
       where community_id = $1::uuid and player_id = $2::uuid and id = $3::uuid""",
    @[textParam(communityId), textParam(playerId), textParam(claimId)])
  if claim.isNone:
    return ceClaimNotFound
  if claim.get.get("user_id") == adminId:
    return ceSelfDecision

  var outcome = ceConflict
  try:
    db.tx(proc(conn: DbConn) =
      let status = if approve: "approved" else: "rejected"
      # The CHECK constraint requires a reason whenever the row is decided.
      let decidedReason =
        if reason.strip().len > 0: reason.strip()
        elif approve: "approved"
        else: "rejected"
      let decided = conn.queryOne(
        """update player.claims
           set status = $4, decided_by = $5::uuid, decided_at = now(),
               reason = nullif($6, '')
           where community_id = $1::uuid and player_id = $2::uuid and id = $3::uuid
             and status = 'pending'
           returning user_id""",
        @[textParam(communityId), textParam(playerId), textParam(claimId),
          textParam(status), textParam(adminId), textParam(decidedReason)])
      if decided.isNone:
        return
      if approve:
        let claimant = decided.get.get("user_id")
        # Serialize approvals for one claimant: under READ COMMITTED two
        # concurrent decisions would both pass the ownership read.
        discard conn.queryOne(
          "select pg_advisory_xact_lock(hashtextextended($1, 0)) as held",
          @[textParam(claimant)])
        # One player per account (D11): approving a second claim cannot bind,
        # and leaving the row pending would hide a refusal the admin has
        # already seen. Close it with the real reason.
        let otherOwned = conn.queryOne(
          """select 1 as found from player.players
             where community_id = $1::uuid and user_id = $2::uuid
               and id <> $3::uuid limit 1""",
          @[textParam(communityId), textParam(claimant),
            textParam(playerId)])
        if otherOwned.isSome:
          discard conn.execUpdate(
            """update player.claims
               set status = 'rejected', decided_by = $4::uuid,
                   decided_at = now(), reason = 'already_claimed'
               where community_id = $1::uuid and player_id = $2::uuid
                 and id = $3::uuid""",
            @[textParam(communityId), textParam(playerId),
              textParam(claimId), textParam(adminId)])
          outcome = ceClaimantOwnsPlayer
          return
        let bound = conn.queryOne(
          """update player.players set user_id = $3::uuid, updated_at = now()
             where community_id = $1::uuid and id = $2::uuid and user_id is null
             returning id""",
          @[textParam(communityId), textParam(playerId), textParam(claimant)])
        if bound.isNone:
          # Another claim won the race; raising rolls the transaction back.
          raise newException(ValueError, "player is already claimed")
        discard conn.execUpdate(
          """update player.claims
             set status = 'rejected', decided_by = $4::uuid, decided_at = now(),
                 reason = 'another_claim_approved'
             where community_id = $1::uuid and player_id = $2::uuid
               and status = 'pending' and id <> $3::uuid""",
          @[textParam(communityId), textParam(playerId), textParam(claimId),
            textParam(adminId)])
      outcome = ceOk)
  except ValueError:
    return ceConflict
  except DbError as error:
    if isUniqueViolation(error):
      return ceAlreadyClaimed
    raise
  outcome

proc release*(db: Db, communityId, playerId, adminId: string,
               claimId, subjectUserId, reason: string): ClaimError =
  ## Shared by the owner's DELETE and the admin's release action. The claim row
  ## is locked first, then the conditional UPDATE decides the winner; zero rows
  ## is a 409, never a 500.
  var outcome = ceConflict
  db.tx(proc(conn: DbConn) =
    discard conn.queryOne(
      """select id from player.players
         where community_id = $1::uuid and id = $2::uuid for update""",
      @[textParam(communityId), textParam(playerId)])
    discard conn.queryOne(
      """select id from player.claims
         where community_id = $1::uuid and player_id = $2::uuid
           and id = $3::uuid and status = 'approved' for update""",
      @[textParam(communityId), textParam(playerId), textParam(claimId)])
    let released = conn.queryOne(
      """update player.claims
         set status = 'released', decided_by = $4::uuid, decided_at = now(),
             reason = nullif($5, '')
         where community_id = $1::uuid and player_id = $2::uuid and id = $3::uuid
           and status = 'approved' and user_id = $6::uuid
         returning user_id""",
      @[textParam(communityId), textParam(playerId), textParam(claimId),
        textParam(adminId), textParam(reason), textParam(subjectUserId)])
    if released.isNone:
      return
    discard conn.execUpdate(
      """update player.players set user_id = null, updated_at = now()
         where community_id = $1::uuid and id = $2::uuid and user_id = $3::uuid""",
      @[textParam(communityId), textParam(playerId), textParam(subjectUserId)])
    outcome = ceOk)
  outcome

proc claimOwner*(db: Db, communityId, playerId, claimId: string): string =
  let row = db.queryOne(
    """select user_id from player.claims
       where community_id = $1::uuid and player_id = $2::uuid and id = $3::uuid""",
    @[textParam(communityId), textParam(playerId), textParam(claimId)])
  if row.isSome: row.get.get("user_id") else: ""

proc approvedClaimFor*(db: Db, communityId, playerId, userId: string): string =
  let row = db.queryOne(
    """select id from player.claims
       where community_id = $1::uuid and player_id = $2::uuid
         and status = 'approved' and user_id = $3::uuid""",
    @[textParam(communityId), textParam(playerId), textParam(userId)])
  if row.isSome: row.get.get("id") else: ""
