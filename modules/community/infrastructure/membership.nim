import std/[options, strutils]
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

type
  MemberWrite* = enum
    mwOk = "ok"
    mwNotFound = "not_found"
    mwLastAdmin = "last_admin"

proc lockCommunity(conn: DbConn, communityId: string) =
  ## Role changes in one community run one at a time. Counting admins is only
  ## safe while no other writer can change the count, so the community row is
  ## the mutex; adding a member does not lower the count and needs no lock.
  discard conn.queryOne(
    """select 1 as ok from platform.community where id = $1::uuid for update""",
    @[textParam(communityId)])

proc adminCount(conn: DbConn, communityId: string): int =
  let row = conn.queryOne(
    """select count(*)::int as admins from community.membership
       where community_id = $1::uuid and role = 'admin'""",
    @[textParam(communityId)])
  parseInt(row.get.get("admins"))

proc setRoleChecked*(db: Db, communityId, userId, role: string): MemberWrite =
  ## Demoting the last admin is refused inside the same transaction that does
  ## the update, so two concurrent demotions cannot both see "another admin".
  discard parseRole(role)
  var outcome = mwNotFound
  db.tx(proc(conn: DbConn) =
    lockCommunity(conn, communityId)
    let row = conn.queryOne(
      """select role from community.membership
         where community_id = $1::uuid and user_id = $2::uuid""",
      @[textParam(communityId), textParam(userId)])
    if row.isNone:
      outcome = mwNotFound
      return
    let current = row.get.get("role")
    if role != "admin" and current == "admin" and
       adminCount(conn, communityId) <= 1:
      outcome = mwLastAdmin
      return
    discard conn.execUpdate(
      """update community.membership set role = $1
         where community_id = $2::uuid and user_id = $3::uuid""",
      @[textParam(role), textParam(communityId), textParam(userId)])
    outcome = mwOk)
  outcome

proc removeChecked*(db: Db, communityId, userId: string): MemberWrite =
  ## Same rule for deletion: the last admin is refused under the same lock.
  var outcome = mwNotFound
  db.tx(proc(conn: DbConn) =
    lockCommunity(conn, communityId)
    let row = conn.queryOne(
      """select role from community.membership
         where community_id = $1::uuid and user_id = $2::uuid""",
      @[textParam(communityId), textParam(userId)])
    if row.isNone:
      outcome = mwNotFound
      return
    if row.get.get("role") == "admin" and adminCount(conn, communityId) <= 1:
      outcome = mwLastAdmin
      return
    discard conn.execUpdate(
      """delete from community.membership
         where community_id = $1::uuid and user_id = $2::uuid""",
      @[textParam(communityId), textParam(userId)])
    outcome = mwOk)
  outcome
