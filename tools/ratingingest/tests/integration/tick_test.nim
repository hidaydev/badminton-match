import std/[options, os, sets, unittest]
import db/db
import ../../main

## Runs only when a scratch v2 database is named, because a tick reads and
## writes it:
##   MAJADU_PG_DSN  a disposable v2 database, migrated and seeded
##
## The test owns only the rows of the community it creates.

let dsn = getEnv("MAJADU_PG_DSN")

if dsn.len == 0:
  echo "SKIP ratingingest suite: MAJADU_PG_DSN not set"
  quit(77)

const epoch = "2026-11-01"
  ## Every date below is absolute: the fixture never asks the database or the
  ## wall clock for "now", so the walk is the same on every run.

var
  database: Db
  communityId: string

proc cleanup() =
  for statement in [
    "delete from rating.events where community_id = $1::uuid",
    "delete from rating.player_state where community_id = $1::uuid",
    "delete from session.game_skips where community_id = $1::uuid",
    "delete from session.games where community_id = $1::uuid",
    "delete from session.participants where community_id = $1::uuid",
    "delete from session.sessions where community_id = $1::uuid",
    "delete from player.players where community_id = $1::uuid"]:
    discard database.execUpdate(statement, @[textParam(communityId)])
  discard database.execUpdate(
    "delete from platform.community where id = $1::uuid",
    @[textParam(communityId)])

proc seedSession(date, approvedAt: string): string =
  database.queryOne(
    """insert into session.sessions
         (community_id, title, session_date, status, source, version,
          approved_at)
       values ($1::uuid, 'Ticker night', $2::date, 'locked', 'manual', 1,
               $3::timestamptz)
       returning id""",
    @[textParam(communityId), textParam(date), textParam(approvedAt)]
  ).get.get("id")

proc seedEvent(sessionId, date: string) =
  discard database.execUpdate(
    """insert into rating.events (community_id, local_date, event_type, source_id)
       values ($1::uuid, $2::date, 'session', $3::uuid)""",
    @[textParam(communityId), textParam(date), textParam(sessionId)])

database = openDb(dsn, 1)
let existing = database.queryOne(
  "select id from platform.community where slug = 'ticker-club'")
if existing.isSome:
  communityId = existing.get.get("id")
  cleanup()
communityId = database.queryOne(
  """insert into platform.community (slug, name, timezone)
     values ('ticker-club', 'Ticker Club', 'Asia/Jakarta')
     returning id""").get.get("id")

# A tick must replay in approval order, not in session-date order: the oldest
# session was approved last, so it is the one the ledger has not seen at all.
let late = seedSession(epoch, "2026-11-02 20:00:00+07")
let early = seedSession("2026-11-05", "2026-11-01 20:00:00+07")
let seen = seedSession("2026-11-03", "2026-11-03 20:00:00+07")
seedEvent(seen, "2026-11-03")
# An unapproved session is never pending, whatever its dates.
let draft = database.queryOne(
  """insert into session.sessions
       (community_id, title, session_date, status, source, version)
     values ($1::uuid, 'Draft night', '2026-11-04', 'draft', 'manual', 1)
     returning id""", @[textParam(communityId)]).get.get("id")

suite "ratingingest tick":
  test "a tick only asks about sessions the ledger has not seen":
    var pending = initHashSet[string]()
    for id in pendingSessions(database, communityId):
      pending.incl(id)
    check pending == toHashSet([early, late])
    check seen notin pending
    check draft notin pending

  test "the walk is in approval order, not session-date order":
    check pendingSessions(database, communityId) == @[early, late]

  test "the ledger holds exactly the one event the fixture created":
    let events = database.query(
      """select source_id::text as source_id, local_date::text as local_date
         from rating.events where community_id = $1::uuid
         order by local_date, source_id""",
      @[textParam(communityId)])
    check events.len == 1
    check events[0].get("source_id") == seen
    check events[0].get("local_date") == "2026-11-03"

  test "a seen session leaves the walk when it is ingested":
    seedEvent(early, "2026-11-05")
    check pendingSessions(database, communityId) == @[late]