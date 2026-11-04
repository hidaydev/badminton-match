import std/[json, options]
import db/db
import ../domain/lifecycle
import ../domain/audit
import ./audit_store

type
  LifecycleResult* = enum
    lrOk = "ok"
    lrNotFound = "not_found"
    lrAlready = "already_anonymized"

proc communitiesOf(conn: DbConn, userId: string): seq[string] =
  ## One row per community the account touched, so every later write carries an
  ## explicit community_id instead of sweeping across tenants.
  for row in conn.query(
    """select distinct community_id from player.claims where user_id = $1::uuid
       union
       select distinct community_id from player.players where user_id = $1::uuid""",
    @[textParam(userId)]):
    result.add(row.get("community_id"))

proc releaseClaims(conn: DbConn, communityIds: seq[string], userId, actorId,
                   reason: string) =
  ## Claims are closed, never deleted: the reconciliation trail has to survive
  ## the account. The CHECK constraint requires a reason on every decided row.
  for communityId in communityIds:
    discard conn.execUpdate(
      """update player.claims
         set status = case when status = 'approved' then 'released' else 'rejected' end,
             reason = $3, decided_by = $4::uuid, decided_at = now()
         where community_id = $1::uuid and user_id = $2::uuid
           and status in ('approved', 'pending')""",
      @[textParam(communityId), textParam(userId), textParam(reason),
        textParam(actorId)])

proc anonymize*(db: Db, userId, actorId, reason: string): LifecycleResult =
  ## One transaction: close claims, unlink players, drop the sessions and
  ## rewrite the identity. Rating rows are untouched, because the history belongs
  ## to the player, not to the account.
  var outcome = lrOk
  discard db.tx(proc(conn: DbConn): int =
    let user = conn.queryOne(
      """select google_sub, email_hash from platform.user
         where id = $1::uuid for update""",
      @[textParam(userId)])
    if user.isNone:
      outcome = lrNotFound
      return 0
    if isAnonymized(user.get.get("email_hash"), userId):
      outcome = lrAlready
      return 0
    let identity = anonymizedIdentity(user.get.get("google_sub"), userId)
    let communityIds = communitiesOf(conn, userId)
    releaseClaims(conn, communityIds, userId, actorId, reason)
    for communityId in communityIds:
      discard conn.execUpdate(
        """update player.players set user_id = null, updated_at = now()
           where community_id = $1::uuid and user_id = $2::uuid""",
        @[textParam(communityId), textParam(userId)])
    discard conn.execUpdate(
      """delete from account.sessions where user_id = $1::uuid""",
      @[textParam(userId)])
    discard conn.execUpdate(
      """delete from platform.ws_ticket where user_id = $1::uuid""",
      @[textParam(userId)])
    discard conn.execUpdate(
      """update platform.user
         set google_sub = $2, email_hash = $3, display_name = $4
         where id = $1::uuid""",
      @[textParam(userId), textParam(identity.sub),
        textParam(identity.emailHash), textParam(identity.displayName)])
    1)
  if outcome == lrOk:
    recordAudit(db, auditEvent("account.anonymize", communityId = "",
      actorId = actorId, actorRole = "platform_owner",
      targetKind = "user", targetId = userId, reason = reason,
      requestId = "cli").withEvidence(newJObject(), %*{"reason": reason}))
  outcome
