## The membership statements every caller shares: the role lookup and the plain
## add. The accept-invite path keeps its own rank-guarded upsert, because an
## invite may promote an existing member but must never demote one.

import db/db

const memberRoleSql* = """select role from community.membership
       where community_id = $1::uuid and user_id = $2::uuid"""

const memberInsertSql = """insert into community.membership
       (community_id, user_id, role)
     values ($1::uuid, $2::uuid, $3)
     on conflict (community_id, user_id) do nothing"""

proc addMemberConn*(conn: DbConn, communityId, userId, role: string): bool =
  ## True only when this call created the row; an existing member is a no-op.
  conn.execUpdate(memberInsertSql,
    @[textParam(communityId), textParam(userId), textParam(role)]) > 0