## The membership statements every caller shares: the role lookup, the plain
## add and the unconditional upsert. The accept-invite path compares ranks in
## the domain before it calls the upsert, so an invite may promote an existing
## member but must never demote one.

import db/db
import ../../account/domain/roles

const memberRoleSql* = """select role from community.membership
       where community_id = $1::uuid and user_id = $2::uuid"""

const memberInsertSql = """insert into community.membership
       (community_id, user_id, role)
     values ($1::uuid, $2::uuid, $3)
     on conflict (community_id, user_id) do nothing"""

const memberUpsertSql = """insert into community.membership
       (community_id, user_id, role)
     values ($1::uuid, $2::uuid, $3)
     on conflict (community_id, user_id) do update
       set role = excluded.role"""

proc addMemberConn*(conn: DbConn, communityId, userId: string, role: Role): bool =
  ## True only when this call created the row; an existing member is a no-op.
  conn.execUpdate(memberInsertSql,
    @[textParam(communityId), textParam(userId), textParam($role)]) > 0

proc upsertMemberConn*(conn: DbConn, communityId, userId: string,
                       role: Role): bool =
  ## Unconditional role write. The caller compares ranks first, so a plain
  ## upsert cannot demote: only a promotion reaches this statement.
  conn.execUpdate(memberUpsertSql,
    @[textParam(communityId), textParam(userId), textParam($role)]) > 0