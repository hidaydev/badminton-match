import std/options
import db/db
import sha256
import ../../account/domain/roles
import token
import ./membership_sql

type
  AcceptOutcome* = enum
    aoOk = "ok"
    aoNotFound = "not_found"
    aoUsed = "used"
    aoExpired = "expired"
    aoEmailMismatch = "email_mismatch"

  AcceptResult* = object
    outcome*: AcceptOutcome
    communityId*: string
    role*: string
    emailHash*: string

proc create*(db: Db, communityId, emailHash: string, role: Role,
             createdBy: string, ttlDays: int): string =
  ## Returns the opaque token exactly once. The invite is bound to the address,
  ## so a forwarded token is worthless without the matching account.
  let token = newOpaqueToken()
  discard db.execUpdate(
    """insert into community.invite
         (community_id, token_hash, email_hash, role, created_by, expires_at)
       values ($1::uuid, decode($2,'hex'), $3, $4, $5::uuid,
               case when $6 > 0 then now() + make_interval(days => $6) else null end)""",
    @[
      textParam(communityId),
      textParam(sha256Hex(token)),
      textParam(emailHash),
      textParam($role),
      textParam(createdBy),
      intParam(ttlDays.int64),
    ])
  token

proc lookup*(db: Db, token: string): AcceptResult =
  ## Read-only inspection. Acceptance is decided by `accept`, which also claims
  ## the row atomically.
  ##
  ## An invite token is presented before a community is chosen, which is why the
  ## row names its own community. Under the policy set a plain read here returns
  ## nothing and every invitation link becomes "not found", so the read goes
  ## through the definer function once step 2 installs it and stays in process
  ## before that.
  var row: Option[Row] = none(Row)
  if db.functionExists("community.invite_by_token(bytea)"):
    row = db.queryOne(
      """select community_id, role, email_hash,
                accepted_at is not null as accepted,
                expires_at is not null and expires_at <= now() as expired
         from community.invite_by_token(decode($1,'hex'))""",
      @[textParam(sha256Hex(token))])
  else:
    row = db.queryOne(
      """select community_id, role, email_hash,
                accepted_at is not null as accepted,
                expires_at is not null and expires_at <= now() as expired
         from community.invite where token_hash = decode($1,'hex')""",
      @[textParam(sha256Hex(token))])
  if row.isNone:
    return AcceptResult(outcome: aoNotFound)
  let detail = AcceptResult(communityId: row.get.getUuid("community_id"),
    role: row.get.get("role"), emailHash: row.get.get("email_hash"))
  if row.get.getBool("accepted"):
    return AcceptResult(outcome: aoUsed, communityId: detail.communityId,
      role: detail.role, emailHash: detail.emailHash)
  if row.get.getBool("expired"):
    return AcceptResult(outcome: aoExpired, communityId: detail.communityId,
      role: detail.role, emailHash: detail.emailHash)
  detail

proc acceptPendingForEmail*(db: Db, userId, emailHash: string):
    seq[tuple[communityId, role: string]] =
  ## Invitations bound to this address are granted at login, which is how the
  ## first admin named at community creation becomes an admin (COM-01). Only
  ## memberships this call actually created are reported: an existing member
  ## already had the grant, and reporting it again would audit a no-op.
  ##
  ## An address is presented before any community is chosen, so this is a
  ## cross-tenant write. It loops the root table and claims one community at a
  ## time on a facade that declares it; a single statement spanning invites would
  ## match nothing under the policy set and the first admin would never be
  ## granted, with a green login and no error.
  var joined: seq[tuple[communityId, role: string]] = @[]
  for root in db.query("select id from platform.community order by slug"):
    let communityId = root.get("id")
    let community = db.scoped(communityId)
    community.tx(proc(conn: DbConn) =
      for row in conn.query(
        """update community.invite
           set accepted_at = now()
           where community_id = $2::uuid
             and email_hash = $1 and accepted_at is null
             and (expires_at is null or expires_at > now())
           returning community_id, role""",
        @[textParam(emailHash), textParam(communityId)]):
        if addMemberConn(conn, row.getUuid("community_id"), userId,
            parseRole(row.get("role"))):
          joined.add((communityId: row.getUuid("community_id"),
            role: row.get("role"))))
  joined

proc accept*(db: Db, token, userId, emailHash: string): AcceptResult =
  ## One conditional UPDATE claims the invite, so two concurrent redemptions
  ## cannot both succeed. The email check happens before the claim and leaves
  ## the invite usable by its intended recipient.
  let found = lookup(db, token)
  if found.outcome == aoNotFound:
    return found
  if found.emailHash != emailHash:
    return AcceptResult(outcome: aoEmailMismatch)
  if found.outcome == aoUsed:
    # Login claims every unused invite for the address, so the recipient who
    # follows the link afterwards finds their own invitation already redeemed.
    # Same address, same outcome: report the membership it granted. The read
    # declares the community the token named, which the token's own row supplied.
    let held = db.scoped(found.communityId).queryOne(memberRoleSql,
      @[textParam(found.communityId), textParam(userId)])
    if held.isSome:
      return AcceptResult(outcome: aoOk, communityId: found.communityId,
        role: held.get.get("role"), emailHash: found.emailHash)
    return found
  if found.outcome == aoExpired:
    return found

  var communityId, role: string
  let community = db.scoped(found.communityId)
  community.tx(proc(conn: DbConn) =
    let row = conn.queryOne(
      """update community.invite
         set accepted_at = now()
         where token_hash = decode($1,'hex')
           and accepted_at is null
           and (expires_at is null or expires_at > now())
           and email_hash = $2
         returning community_id, role""",
      @[textParam(sha256Hex(token)), textParam(emailHash)])
    if row.isSome:
      communityId = row.get.getUuid("community_id")
      # An invite may promote an existing member (the screen offers host and
      # admin), but never demote one: the rank comparison happens before the
      # write, so the plain upsert only ever raises a member's role.
      let wanted = parseRole(row.get.get("role"))
      let held = conn.queryOne(memberRoleSql,
        @[textParam(communityId), textParam(userId)])
      if held.isNone or promotes(parseRole(held.get.get("role")), wanted):
        discard upsertMemberConn(conn, communityId, userId, wanted)
      # The audit and the response must name the role the member ended up with,
      # not the one the invite asked for (a second invite may be a no-op).
      let settled = conn.queryOne(memberRoleSql,
        @[textParam(communityId), textParam(userId)])
      if settled.isSome:
        role = settled.get.get("role"))

  if communityId.len > 0:
    AcceptResult(outcome: aoOk, communityId: communityId, role: role)
  else:
    # Someone else claimed it between the lookup and the UPDATE.
    AcceptResult(outcome: aoUsed)
