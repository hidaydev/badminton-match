## Rating source reads for the admin sign-off routes. The list is one union of
## the events and the tournaments that were never ingested, so the page window
## and the total come from the database rather than from two unbounded halves.
## The delivery layer renders these rows; it does not query them.

import std/[options, strutils]
import db/db

const sourcesSql = """
    select id, event_type, local_date, source_id, deltas, finalized,
           finalized_at
    from (
      select e.id, e.event_type, e.local_date::text as local_date,
             coalesce(e.source_id::text, '') as source_id,
             e.point_entries::int as deltas,
             coalesce(s.finalized, false) as finalized,
             s.finalized_at::text as finalized_at,
             e.created_at as sort_at
      from rating.events e
      left join rating.sources s
        on s.community_id = e.community_id and s.source_id = e.source_id
      where e.community_id = $1::uuid
      union all
      select t.id, 'tournament' as event_type, t.event_date::text,
             t.id::text as source_id, 0 as deltas,
             coalesce(s.finalized, false) as finalized,
             s.finalized_at::text as finalized_at,
             t.created_at as sort_at
      from tournament.tournaments t
      left join rating.sources s
        on s.community_id = t.community_id and s.source_id = t.id
      where t.community_id = $1::uuid
        and not exists (
          select 1 from rating.events e
          where e.community_id = t.community_id
            and e.event_type = 'tournament' and e.source_id = t.id)
    ) sources
  """

proc list*(db: Db, communityId: string, limit, offset: int): seq[Row] =
  for row in db.query(
    sourcesSql & """ order by local_date desc, sort_at desc
                     limit $2 offset $3""",
    @[textParam(communityId), intParam(limit.int64),
      intParam(offset.int64)]):
    result.add(row)

proc total*(db: Db, communityId: string): int =
  let row = db.queryOne(
    "select count(*)::int as total from (" & sourcesSql & ") sources",
    @[textParam(communityId)])
  if row.isSome: parseInt(row.get.get("total")) else: 0

proc eventExists*(db: Db, communityId, eventId: string): bool =
  db.queryOne(
    """select 1 as ok from rating.events
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(eventId)]).isSome

proc eventSource*(db: Db, communityId, eventId: string): Option[Row] =
  db.queryOne(
    """select event_type, source_id::text as source_id from rating.events
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(eventId)])

proc sessionExists*(db: Db, communityId, sessionId: string): bool =
  db.queryOne(
    """select 1 as ok from session.sessions
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)]).isSome

proc eventForSourceExists*(db: Db, communityId, sourceId: string): bool =
  db.queryOne(
    """select 1 as ok from rating.events
       where community_id = $1::uuid and source_id = $2::uuid""",
    @[textParam(communityId), textParam(sourceId)]).isSome

proc alreadyFinalized*(db: Db, communityId, eventId: string): bool =
  db.queryOne(
    """select 1 as ok from rating.sources s
       where s.community_id = $1::uuid and s.finalized
         and (s.source_id = $2::uuid
              or s.source_id = (select e.source_id from rating.events e
                                where e.community_id = $1::uuid
                                  and e.id = $2::uuid))""",
    @[textParam(communityId), textParam(eventId)]).isSome
