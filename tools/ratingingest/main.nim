import std/[json, options, os]
import cli
import db/db
import platform/config/store
import rating/domain/rating
import rating/infrastructure/ingest
import achievement/infrastructure/backfill
import rating/infrastructure/params
import rating/read
import session/lifecycle

const
  program = "ratingingest"
  usage = """Usage: ratingingest <tick|session <id> --community <slug>|rebuild --community <slug>>

  tick                          ingest every new approved session, then award badges
  session <id> --community <s>  ingest one session
  rebuild --community <slug>    wipe and replay that community's rating

Requires MAJADU_PG_DSN. Every mode is idempotent, so running twice is safe."""

proc communityIdOf(db: Db, slug: string): string =
  let row = db.queryOne(
    "select id from platform.community where slug = $1", @[textParam(slug)])
  if row.isNone:
    fail(program, "no community with slug " & slug)
  row.get.get("id")

proc planFor(db: Db, snapshot: Snapshot, communityId: string): RatingParams =
  loadRatingParams(snapshot, communitySettings(db, communityId))

proc absentSessionMessage*(sessionId, slug: string): string =
  ## One line that names both values the operator typed. A session outside the
  ## community and a session that does not exist are the same answer here.
  "no session " & sessionId & " in community " & slug

proc sessionInCommunity(db: Db, communityId, sessionId: string): bool =
  ## Asked before ingest: `ingestSession` returns silently for a session that is
  ## not this community's, which would spell the operator's wrong slug and a
  ## session with nothing new as the same `events:0`.
  db.queryOne(
    """select 1 as found from session.sessions
       where id = $1::uuid and community_id = $2::uuid""",
    @[textParam(sessionId), textParam(communityId)]).isSome

proc pendingSessions*(db: Db, communityId: string): seq[string] =
  ## Only the approved sessions the ledger has not seen yet. A tick asks once
  ## instead of walking every session and paying three round-trips per no-op.
  ## The order is approval order, the order a rebuild replays: an event's deltas
  ## are computed from the state the events before it left, so session-date
  ## order would award a different multiplier.
  for row in db.query(
    """select s.id
       from session.sessions s
       where s.community_id = $1::uuid and s.approved_at is not null
         and s.status in """ & approvedStatuses & """
         and not exists (
           select 1 from rating.events e
           where e.community_id = s.community_id
             and e.event_type = 'session' and e.source_id = s.id)
       order by s.approved_at, s.id""", @[textParam(communityId)]):
    result.add(row.get("id"))

proc main() =
  if paramCount() < 1:
    echo usage
    quit(2)
  let db = openDb(dsnOrFail(program), 1)
  defer: db.close()
  let snapshot = loadSnapshot(db)
  let command = paramStr(1)
  var slug = ""
  var sessionId = ""
  for (flag, value) in flags(program, 2, ["--community", "--session"]):
    case flag
    of "--community":
      slug = value
    of "--session":
      sessionId = value
    else:
      if command == "session" and sessionId.len == 0:
        sessionId = flag
      else:
        usageFail(program, "unknown argument: " & flag)

  var communities = 0
  var events = 0
  var deltas = 0
  var awarded = 0
  case command
  of "tick":
    for row in db.query("select id from platform.community order by slug"):
      let communityId = row.get("id")
      let params = planFor(db, snapshot, communityId)
      for id in pendingSessions(db, communityId):
        let result = ingestSession(db, communityId, id, params)
        events += result.events
        deltas += result.deltas
      awarded += backfill(db, communityId,
        latestEventDate(db, communityId), params).awarded
      inc communities
  of "session":
    if slug.len == 0 or sessionId.len == 0:
      usageFail(program, "session needs an id and --community <slug>")
    let communityId = communityIdOf(db, slug)
    if not sessionInCommunity(db, communityId, sessionId):
      fail(program, absentSessionMessage(sessionId, slug))
    let params = planFor(db, snapshot, communityId)
    let result = ingestSession(db, communityId, sessionId, params)
    events += result.events
    deltas += result.deltas
    awarded += backfill(db, communityId,
      latestEventDate(db, communityId), params).awarded
    communities = 1
  of "rebuild":
    if slug.len == 0:
      usageFail(program, "rebuild needs --community <slug>")
    let communityId = communityIdOf(db, slug)
    let params = planFor(db, snapshot, communityId)
    let result = rebuild(db, communityId, params)
    events += result.events
    deltas += result.deltas
    awarded += backfill(db, communityId,
      latestEventDate(db, communityId), params).awarded
    communities = 1
  else:
    echo usage
    quit(2)

  echo $(%*{"communities": communities, "events": events, "deltas": deltas,
    "awarded": awarded})

when isMainModule:
  main()
