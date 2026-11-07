import std/options
import db/db
import ../../account/domain/roles
import ./membership_sql

type
  JoinRequest* = object
    id*: string
    userId*: string
    displayName*: string
    createdAt*: string

proc request*(db: Db, communityId, userId: string): bool =
  ## Idempotent by construction: a second pending request is a no-op, which is
  ## also what keeps the response byte-identical for the anti-enumeration rule.
  ## Returns whether this call created the row, so a caller can tell the two
  ## cases apart; `execUpdate(...) >= 0` was always true and told it nothing.
  db.execUpdate(
    """insert into community.join_request (community_id, user_id)
       values ($1::uuid, $2::uuid)
       on conflict do nothing""",
    @[textParam(communityId), textParam(userId)]) > 0

proc listPending*(db: Db, communityId: string): seq[JoinRequest] =
  for row in db.query(
    """select r.id, r.user_id, u.display_name, r.created_at::text as created_at
       from community.join_request r
       join platform.user u on u.id = r.user_id
       where r.community_id = $1::uuid and r.status = 'pending'
       order by r.created_at""",
    @[textParam(communityId)]):
    result.add(JoinRequest(id: row.get("id"), userId: row.get("user_id"),
      displayName: row.get("display_name"), createdAt: row.get("created_at")))

proc decide*(db: Db, communityId, requestId, actorId: string,
             role: string, approve: bool): bool =
  ## `WHERE status = 'pending' RETURNING` makes two admins clicking at once
  ## resolve to exactly one decision; the loser sees 404/409, not a second write.
  if approve:
    discard parseRole(role)
  var decided = false
  db.tx(proc(conn: DbConn) =
    let row = conn.queryOne(
      """update community.join_request
         set status = case when $3 then 'approved' else 'rejected' end,
             decided_at = now(),
             decided_by = $4::uuid
         where community_id = $1::uuid and id = $2::uuid and status = 'pending'
         returning user_id""",
      @[
        textParam(communityId),
        textParam(requestId),
        boolParam(approve),
        textParam(actorId),
      ])
    if row.isSome:
      decided = true
      if approve:
        discard addMemberConn(conn, communityId,
          row.get.get("user_id"), role))
  decided
