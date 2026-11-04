import std/[json, options, os]
import db/db
import platform/config/store
import rating/domain/rating
import rating/infrastructure/ingest
import achievement/infrastructure/backfill
import rating/infrastructure/params

const usage = """Usage: ratingingest <tick|session <id> --community <slug>|rebuild --community <slug>>

  tick                          ingest every approved session of every community
  session <id> --community <s>  ingest one session
  rebuild --community <slug>    wipe and replay that community's rating

Requires MAJADU_PG_DSN. Every mode is idempotent, so running twice is safe."""

proc fail(message: string) {.noreturn.} =
  stderr.writeLine "ratingingest: " & message
  quit(2)

proc communitySettings(db: Db, communityId: string): JsonNode =
  let row = db.queryOne(
    """select values::text as values from community.settings
       where community_id = $1::uuid""", @[textParam(communityId)])
  if row.isSome: parseJson(row.get.get("values")) else: newJObject()

proc communityIdOf(db: Db, slug: string): string =
  let row = db.queryOne(
    "select id from platform.community where slug = $1", @[textParam(slug)])
  if row.isNone:
    fail "no community with slug " & slug
  row.get.get("id")

proc planFor(db: Db, snapshot: Snapshot, communityId: string): RatingParams =
  loadRatingParams(snapshot, communitySettings(db, communityId))

proc approvedSessions(db: Db, communityId: string): seq[string] =
  for row in db.query(
    """select id from session.sessions
       where community_id = $1::uuid and approved_at is not null
         and status in ('locked', 'published', 'completed', 'archived')
       order by session_date, id""", @[textParam(communityId)]):
    result.add(row.get("id"))

proc main() =
  if paramCount() < 1:
    echo usage
    quit(2)
  let dsn = getEnv("MAJADU_PG_DSN")
  if dsn.len == 0:
    fail "MAJADU_PG_DSN is required"
  let db = openDb(dsn, 1)
  defer: db.close()
  let snapshot = loadSnapshot(db)
  let command = paramStr(1)
  var slug = ""
  var sessionId = ""
  var index = 2
  while index <= paramCount():
    case paramStr(index)
    of "--community":
      index.inc; slug = paramStr(index)
    of "--session":
      index.inc; sessionId = paramStr(index)
    else:
      if command == "session" and sessionId.len == 0:
        sessionId = paramStr(index)
      else:
        fail "unknown argument: " & paramStr(index)
    index.inc

  var communities = 0
  var events = 0
  var deltas = 0
  var awarded = 0
  case command
  of "tick":
    for row in db.query("select id from platform.community order by slug"):
      let communityId = row.get("id")
      let params = planFor(db, snapshot, communityId)
      for id in approvedSessions(db, communityId):
        let result = ingestSession(db, communityId, id, params)
        events += result.events
        deltas += result.deltas
      awarded += backfill(db, communityId).awarded
      inc communities
  of "session":
    if slug.len == 0 or sessionId.len == 0:
      fail "session needs an id and --community <slug>"
    let communityId = communityIdOf(db, slug)
    let result = ingestSession(db, communityId, sessionId,
      planFor(db, snapshot, communityId))
    events += result.events
    deltas += result.deltas
    awarded += backfill(db, communityId).awarded
    communities = 1
  of "rebuild":
    if slug.len == 0:
      fail "rebuild needs --community <slug>"
    let communityId = communityIdOf(db, slug)
    let result = rebuild(db, communityId, planFor(db, snapshot, communityId))
    events += result.events
    deltas += result.deltas
    awarded += backfill(db, communityId).awarded
    communities = 1
  else:
    echo usage
    quit(2)

  echo $(%*{"communities": communities, "events": events, "deltas": deltas,
    "awarded": awarded})

when isMainModule:
  main()
