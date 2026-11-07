import std/options
import db/db
import sha256
import ../../account/domain/roles
import ./tokens

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

proc create*(db: Db, communityId, emailHash, role, createdBy: string,
             ttlDays: int): string =
  ## Returns the opaque token exactly once. The invite is bound to the address,
  ## so a forwarded token is worthless without the matching account.
  discard parseRole(role)
  let token = newToken()
  discard db.execUpdate(
    """insert into community.invite
         (community_id, token_hash, email_hash, role, created_by, expires_at)
       values ($1::uuid, decode($2,'hex'), $3, $4, $5::uuid,
               case when $6 > 0 then now() + make_interval(days => $6) else null end)""",
    @[
      textParam(communityId),
      textParam(sha256Hex(token)),
      textParam(emailHash),
      textParam(role),
      textParam(createdBy),
      intParam(ttlDays.int64),
    ])
  token

proc lookup*(db: Db, token: string): AcceptResult =
  ## Read-only inspection. Acceptance is decided by `accept`, which also claims
  ## the row atomically.
  let row = db.queryOne(
    """select community_id, role, email_hash,
              accepted_at is not null as accepted,
              expires_at is not null and expires_at <= now() as expired
       from community.invite where token_hash = decode($1,'hex')""",
    @[textParam(sha256Hex(token))])
  if row.isNone:
    return AcceptResult(outcome: aoNotFound)
  let detail = AcceptResult(communityId: row.get.get("community_id"),
    role: row.get.get("role"), emailHash: row.get.get("email_hash"))
  if row.get.get("accepted") == "t":
    return AcceptResult(outcome: aoUsed, communityId: detail.communityId,
      role: detail.role, emailHash: detail.emailHash)
  if row.get.get("expired") == "t":
    return AcceptResult(outcome: aoExpired, communityId: detail.communityId,
      role: detail.role, emailHash: detail.emailHash)
  detail

proc acceptPendingForEmail*(db: Db, userId, emailHash: string):
    seq[tuple[communityId, role: string]] =
  ## Invitations bound to this address are granted at login, which is how the
  ## first admin named at community creation becomes an admin (COM-01). Only
  ## memberships this call actually created are reported: an existing member
  ## already had the grant, and reporting it again would audit a no-op.
  var joined: seq[tuple[communityId, role: string]] = @[]
  db.tx(proc(conn: DbConn) =
    for row in conn.query(
      """update community.invite
         set accepted_at = now()
         where email_hash = $1 and accepted_at is null
           and (expires_at is null or expires_at > now())
         returning community_id, role""",
      @[textParam(emailHash)]):
      let granted = conn.queryOne(
        """insert into community.membership (community_id, user_id, role)
           values ($1::uuid, $2::uuid, $3)
           on conflict (community_id, user_id) do nothing
           returning role""",
        @[textParam(row.get("community_id")), textParam(userId),
          textParam(row.get("role"))])
      if granted.isSome:
        joined.add((communityId: row.get("community_id"),
          role: granted.get.get("role"))))
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
    # Same address, same outcome: report the membership it granted.
    let held = db.queryOne(
      """select role from community.membership
         where community_id = $1::uuid and user_id = $2::uuid""",
      @[textParam(found.communityId), textParam(userId)])
    if held.isSome:
      return AcceptResult(outcome: aoOk, communityId: found.communityId,
        role: held.get.get("role"), emailHash: found.emailHash)
    return found
  if found.outcome == aoExpired:
    return found

  var communityId, role: string
  db.tx(proc(conn: DbConn) =
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
      communityId = row.get.get("community_id")
      role = row.get.get("role")
      # An invite may promote an existing member (the screen offers host and
      # admin), but never demote one: the update only fires when the invited
      # role ranks higher.
      discard conn.execUpdate(
        """insert into community.membership (community_id, user_id, role)
           values ($1::uuid, $2::uuid, $3)
           on conflict (community_id, user_id) do update
             set role = excluded.role
             where case excluded.role
                     when 'admin' then 3 when 'host' then 2 else 1 end
                 > case community.membership.role
                     when 'admin' then 3 when 'host' then 2 else 1 end""",
        @[textParam(communityId), textParam(userId), textParam(role)])
      # The audit and the response must name the role the member ended up with,
      # not the one the invite asked for (a second invite may be a no-op).
      let held = conn.queryOne(
        """select role from community.membership
           where community_id = $1::uuid and user_id = $2::uuid""",
        @[textParam(communityId), textParam(userId)])
      if held.isSome:
        role = held.get.get("role"))

  if communityId.len > 0:
    AcceptResult(outcome: aoOk, communityId: communityId, role: role)
  else:
    # Someone else claimed it between the lookup and the UPDATE.
    AcceptResult(outcome: aoUsed)
