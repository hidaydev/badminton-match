import db/db
import ../../account/domain/roles

type
  Member* = object
    userId*: string
    displayName*: string
    role*: string
    joinedAt*: string

proc list*(db: Db, communityId: string): seq[Member] =
  for row in db.query(
    """select m.user_id, u.display_name, m.role, m.created_at::text as created_at
       from community.membership m
       join platform.user u on u.id = m.user_id
       where m.community_id = $1::uuid
       order by m.role desc, u.display_name""",
    @[textParam(communityId)]):
    result.add(Member(userId: row.get("user_id"),
      displayName: row.get("display_name"), role: row.get("role"),
      joinedAt: row.get("created_at")))

proc setRole*(db: Db, communityId, userId, role: string): bool =
  ## Returns false when the user is not a member, so the route can answer 404
  ## instead of pretending the role changed.
  discard parseRole(role)
  db.execUpdate(
    """update community.membership set role = $1
       where community_id = $2::uuid and user_id = $3::uuid""",
    @[textParam(role), textParam(communityId), textParam(userId)]) > 0

proc add*(db: Db, communityId, userId, role: string): bool =
  discard parseRole(role)
  db.execUpdate(
    """insert into community.membership (community_id, user_id, role)
       values ($1::uuid, $2::uuid, $3)
       on conflict (community_id, user_id) do nothing""",
    @[textParam(communityId), textParam(userId), textParam(role)]) > 0

proc remove*(db: Db, communityId, userId: string): bool =
  db.execUpdate(
    """delete from community.membership
       where community_id = $1::uuid and user_id = $2::uuid""",
    @[textParam(communityId), textParam(userId)]) > 0
