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

proc communitiesOf(db: Db): seq[string] =
  ## Every community in the database, read from the one table that carries no
  ## policy. The account's own rows cannot answer this question: under the 0061
  ## policy set a statement with no tenant declared sees none of them, so the old
  ## union over claims, players and membership returned zero communities and the
  ## tool skipped every per-community write while still reporting success.
  ##
  ## `platform.community` is the list janitor.nim sweeps for the same reason:
  ## readable without a tenant, and the caller declares one per row.
  for row in db.query("select id from platform.community order by slug"):
    result.add(row.get("id"))

proc touchesCommunity(scoped: Db, userId: string): bool =
  ## Whether the account has anything in the community this facade declares, so a
  ## sweep does not write three no-op statements across every community. The
  ## predicate names `community_id` as well as relying on the facade: the policy
  ## is not the only thing that has to keep this statement inside one tenant.
  let communityId = scoped.communityOf()
  let row = scoped.queryOne(
    """select exists(select 1 from player.claims where community_id = $1::uuid
                      and user_id = $2::uuid)
          or exists(select 1 from player.players where community_id = $1::uuid
                      and user_id = $2::uuid)
          or exists(select 1 from community.membership
                      where community_id = $1::uuid and user_id = $2::uuid) as touched""",
    @[textParam(communityId), textParam(userId)])
  row.isSome and row.get.getBool("touched")

proc releaseClaims(scoped: Db, userId, actorId, reason: string) =
  ## Claims are closed, never deleted: the reconciliation trail has to survive
  ## the account. The CHECK constraint requires a reason on every decided row.
  discard scoped.execUpdate(
    """update player.claims
       set status = case when status = 'approved' then 'released' else 'rejected' end,
           reason = $2, decided_by = $3::uuid, decided_at = now()
       where community_id = $1::uuid and user_id = $4::uuid
         and status in ('approved', 'pending')""",
    @[textParam(scoped.communityOf()), textParam(reason), textParam(actorId),
      textParam(userId)])

proc anonymize*(db: Db, userId, actorId, reason: string): LifecycleResult =
  ## One transaction: close claims, unlink players, drop the membership rows and
  ## the sessions, then rewrite the identity. Rating rows are untouched, because
  ## the history belongs to the player, not to the account.
  ##
  ## Every tenanted write goes through a facade that declares one community. The
  ## tool runs as `bm2_app`, so under the 0061 policy set a statement with no
  ## tenant declared matches nothing and its writes are refused: the previous
  ## version issued them on the raw connection, deleted no membership row, and
  ## still printed success, which left the anonymised identity an admin.
  var outcome = lrOk
  db.tx(proc(conn: DbConn) =
    let pinned = db.boundTo(conn)
    let user = conn.queryOne(
      """select google_sub, email_hash from platform.user
         where id = $1::uuid for update""",
      @[textParam(userId)])
    if user.isNone:
      outcome = lrNotFound
      return
    if isAnonymized(user.get.get("email_hash"), userId):
      outcome = lrAlready
      return
    let identity = anonymizedIdentity(user.get.get("google_sub"), userId)
    for communityId in communitiesOf(pinned):
      let scoped = pinned.scoped(communityId)
      # One probe per community instead of three no-op writes per community per
      # call: the classes that hang off a community only run where a row exists.
      if not touchesCommunity(scoped, userId):
        continue
      releaseClaims(scoped, userId, actorId, reason)
      discard scoped.execUpdate(
        """update player.players set user_id = null, updated_at = now()
           where community_id = $1::uuid and user_id = $2::uuid""",
        @[textParam(communityId), textParam(userId)])
      # Membership is a link between the account and the community, not match
      # history. Leaving it behind kept an anonymized account as admin, which
      # also made `soleAdmin` refuse every demotion in that community.
      discard scoped.execUpdate(
        """delete from community.membership
           where community_id = $1::uuid and user_id = $2::uuid""",
        @[textParam(communityId), textParam(userId)])
    discard pinned.execUpdate(
      """delete from account.sessions where user_id = $1::uuid""",
      @[textParam(userId)])
    discard pinned.execUpdate(
      """delete from platform.ws_ticket where user_id = $1::uuid""",
      @[textParam(userId)])
    discard pinned.execUpdate(
      """update platform.user
         set google_sub = $2, email_hash = $3, display_name = $4
         where id = $1::uuid""",
      @[textParam(userId), textParam(identity.sub),
        textParam(identity.emailHash), textParam(identity.displayName)])
    # The evidence belongs to the same transaction as the rewrite it records,
    # so an audit failure cannot leave an anonymized account without its row.
    # `community_id = NULL` is load-bearing: 0061 allows a NULL community on
    # this table precisely for platform-level actions.
    recordAuditConn(conn, auditEvent("account.anonymize", communityId = "",
      actorId = actorId, actorRole = "platform_owner",
      targetKind = "user", targetId = userId, reason = reason,
      requestId = "cli").withEvidence(newJObject(), %*{"reason": reason})))
  outcome
