## The session list: one page and its total, filtered and ordered by the
## database. The caller pages with `offset`, so a search is not limited to the
## newest page and the delivery layer only renders the rows.

import std/[options, strutils]
import db/db

const listSql = """
       select s.id, s.title, s.session_date::text as session_date, s.status,
              s.version,
              (select count(*) from session.participants p
                where p.community_id = s.community_id
                  and p.session_id = s.id)::int as player_count,
              (select count(*) from session.games g
                where g.community_id = s.community_id
                  and g.session_id = s.id)::int as total_games
       from session.sessions s
       where s.community_id = $1::uuid
         and ($2 = '' or s.session_date = nullif($2, '')::date)
         and ($3 = '' or strpos(lower(s.title), lower($3)) > 0)
         and ($4 = '' or s.status = $4)
  """

proc page*(db: Db, communityId, date, q, status: string, limit,
           offset: int): seq[Row] =
  for row in db.query(
    listSql & """ order by s.session_date desc, s.updated_at desc
                  limit $5 offset $6""",
    @[textParam(communityId), textParam(date), textParam(q),
      textParam(status), intParam(limit.int64), intParam(offset.int64)]):
    result.add(row)

proc total*(db: Db, communityId, date, q, status: string): int =
  let row = db.queryOne(
    "select count(*)::int as total from (" & listSql & ") session_page",
    @[textParam(communityId), textParam(date), textParam(q),
      textParam(status)])
  if row.isSome: parseInt(row.get.get("total")) else: 0
