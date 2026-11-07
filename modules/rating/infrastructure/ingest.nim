import std/[json, options, strutils, tables]
import db/db
import session/lifecycle
import ../domain/rating
import ./ledger
import ./tournament

type
  IngestResult* = object
    events*: int
    deltas*: int

proc absentPlayers(conn: DbConn, communityId, sessionId: string): seq[string] =
  for row in conn.query(
    """select player_id from session.participants
       where community_id = $1::uuid and session_id = $2::uuid and is_absent""",
    @[textParam(communityId), textParam(sessionId)]):
    result.add(row.get("player_id"))

proc sidePlayers(row: Row, side: string): seq[string] =
  for slot in ["1", "2"]:
    let key = side & slot
    if row[key].isSome and row.get(key).len > 0:
      result.add(row.get(key))

proc active(players, absent, skipped: seq[string]): seq[string] =
  for player in players:
    if player notin absent and player notin skipped:
      result.add(player)

proc awardSide(conn: DbConn, communityId: string, side: string, won: bool,
               row: Row, absent, skipped: seq[string]): int =
  let activePlayers = active(sidePlayers(row, side), absent, skipped)
  if activePlayers.len == 0:
    return 0
  addState(conn, communityId, activePlayers, won)
  activePlayers.len

proc ingestGame(conn: DbConn, communityId: string, row: Row,
                absent, skipped: seq[string]): int =
  ## v1's gate: a game needs a real present player on both sides, but a side
  ## whose players were all substituted still keeps the game alive for the
  ## other side. Skipped players are present; absent ones are not.
  let sideA = sidePlayers(row, "side_a")
  let sideB = sidePlayers(row, "side_b")
  let presentA = active(sideA, absent, newSeq[string]())
  let presentB = active(sideB, absent, newSeq[string]())
  if presentA.len == 0 or presentB.len == 0:
    return 0
  let winner = row.get("winner")
  result += awardSide(conn, communityId, "side_a", winner == "a", row,
    absent, skipped)
  result += awardSide(conn, communityId, "side_b", winner == "b", row,
    absent, skipped)

proc ingestSessionConn(conn: DbConn, communityId, sessionId: string,
                       params: RatingParams,
                       preserved: Table[string, string]): IngestResult =
  let existing = conn.queryOne(
    """select id from rating.events
       where community_id = $1::uuid and event_type = 'session'
         and source_id = $2::uuid limit 1""",
    @[textParam(communityId), textParam(sessionId)])
  if existing.isSome:
    return
  let session = conn.queryOne(
    """select session_date::text as session_date, status, approved_at
       from session.sessions
       where community_id = $1::uuid and id = $2::uuid
       for update""",
    @[textParam(communityId), textParam(sessionId)])
  if session.isNone:
    return
  let current = session.get
  if not isRated(current["approved_at"], current.get("status")):
    return
  let event = insertEvent(conn, communityId, "session", sessionId,
    current.get("session_date"), preserved)
  if event.isNone:
    return
  let eventId = event.get.get("id")
  result.events = 1
  let absent = absentPlayers(conn, communityId, sessionId)
  var skipRows = initTable[string, seq[string]]()
  for entry in conn.query(
    """select round_no, court_no, player_id::text as player_id
       from session.game_skips
       where community_id = $1::uuid and session_id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)]):
    skipRows.mgetOrPut(entry.get("round_no") & "-" & entry.get("court_no"),
      @[]).add(entry.get("player_id"))
  var entries = 0
  for row in conn.query(
    """select round_no, court_no, winner,
              coalesce(side_a1::text, '') as side_a1,
              coalesce(side_a2::text, '') as side_a2,
              coalesce(side_b1::text, '') as side_b1,
              coalesce(side_b2::text, '') as side_b2
       from session.game_results
       where community_id = $1::uuid and session_id = $2::uuid
         and status = 'played' and winner <> ''
       order by round_no, court_no""",
    @[textParam(communityId), textParam(sessionId)]):
    let skipped = skipRows.getOrDefault(
      row.get("round_no") & "-" & row.get("court_no"))
    entries += ingestGame(conn, communityId, row, absent, skipped)
  if entries == 0:
    # An approved session with no playable game contributes nothing. Leaving
    # the empty event behind would show a rating source with zero entries and
    # keep it in the ledger after the points were withdrawn.
    discard conn.execUpdate(
      "delete from rating.events where community_id = $1::uuid and id = $2::uuid",
      @[textParam(communityId), textParam(eventId)])
    result.events = 0
    return
  result.deltas = entries
  discard conn.execUpdate(
    """update rating.events set point_entries = $3::int
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(eventId), intParam(entries.int64)])

proc ingestSession*(db: Db, communityId, sessionId: string,
                    params: RatingParams): IngestResult =
  ## Exactly one event per approved session; a second run is a no-op.
  var outcome: IngestResult
  db.tx(proc(conn: DbConn) =
    lockCommunity(conn, communityId)
    outcome = ingestSessionConn(conn, communityId, sessionId, params,
      initTable[string, string]()))
  outcome

proc sourceFinalized*(db: Db, communityId, sourceId: string): bool =
  ## True when the source was signed off. The incremental paths (ingest,
  ## revert, ticker) must respect it; a full rebuild leaves the row alone, so
  ## the sign-off survives a recompute.
  db.queryOne(finalizedSql,
    @[textParam(communityId), textParam(sourceId)]).isSome

proc eventSource(db: Db, communityId, eventId: string): Option[string] =
  ## The source behind an event, so a route that names an event can still ask
  ## about (and toggle) the source's sign-off. Events without a source (manual
  ## adjustments) have nothing to report.
  let row = db.queryOne(
    """select source_id::text as source_id from rating.events
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(eventId)])
  if row.isNone or row.get["source_id"].isNone:
    return none(string)
  some(row.get.get("source_id"))

proc eventFinalized*(db: Db, communityId, eventId: string): bool =
  ## The delete route names an event, but the sign-off belongs to its source.
  ## An event without a source (manual adjustment) is never final.
  let source = eventSource(db, communityId, eventId)
  source.isSome and sourceFinalized(db, communityId, source.get)

proc sourceKind(db: Db, communityId, sourceId: string): Option[string] =
  ## A source is a session or a tournament; the id itself says which table to
  ## look in, and an unknown id stays unknown instead of being assumed.
  if db.queryOne(
      """select 1 as ok from session.sessions
         where community_id = $1::uuid and id = $2::uuid""",
      @[textParam(communityId), textParam(sourceId)]).isSome:
    return some("session")
  if db.queryOne(
      """select 1 as ok from tournament.tournaments
         where community_id = $1::uuid and id = $2::uuid""",
      @[textParam(communityId), textParam(sourceId)]).isSome:
    return some("tournament")
  none(string)

proc setFinalized*(db: Db, communityId, sourceId: string,
                   finalized: bool): Option[JsonNode] =
  ## Signs a source off, or withdraws it. `sourceId` may also be an event id,
  ## because the ledger the admin sees is the event list; the source is what
  ## actually gets the flag. Returns the source row, or none when neither an
  ## event, a session nor a tournament owns that id.
  var source = sourceId
  let fromEvent = eventSource(db, communityId, sourceId)
  if fromEvent.isSome:
    source = fromEvent.get
  let kind = sourceKind(db, communityId, source)
  if kind.isNone:
    return none(JsonNode)
  let row = db.queryOne(
    """insert into rating.sources as s
         (community_id, source_id, kind, finalized, finalized_at)
       values ($1::uuid, $2::uuid, $3, $4,
               case when $4 then now() else null end)
       on conflict (community_id, source_id) do update set
         kind = excluded.kind,
         finalized = excluded.finalized,
         finalized_at = excluded.finalized_at
       returning source_id, kind, finalized, finalized_at::text as finalized_at""",
    @[textParam(communityId), textParam(source), textParam(kind.get),
      boolParam(finalized)])
  if row.isNone:
    return none(JsonNode)
  let value = row.get
  some(%*{"sourceId": value.get("source_id"), "kind": value.get("kind"),
    "finalized": value.get("finalized") == "t",
    "finalizedAt": if value["finalized_at"].isSome:
      %value.get("finalized_at") else: newJNull()})

proc dropSourceConn*(conn: DbConn, communityId, sourceId: string): int =
  ## Deletes the sign-off row for a source that itself is being deleted, so a
  ## later source reusing the id cannot inherit an old decision.
  conn.execUpdate(
    """delete from rating.sources
       where community_id = $1::uuid and source_id = $2::uuid""",
    @[textParam(communityId), textParam(sourceId)])

proc dropSource*(db: Db, communityId, sourceId: string): int =
  var removed = 0
  db.tx(proc(conn: DbConn) =
    removed = dropSourceConn(conn, communityId, sourceId))
  removed

proc revertSourceConn*(conn: DbConn, communityId, sourceId: string): int =
  ## Drops one source's event and returns the point entries it carried. The
  ## caller rebuilds the derived counters, because they cannot be recomputed
  ## once the event that produced them is gone.
  let event = conn.queryOne(
    """select id, point_entries from rating.events
       where community_id = $1::uuid and source_id = $2::uuid""",
    @[textParam(communityId), textParam(sourceId)])
  if event.isNone:
    return 0
  result = parseInt(event.get.get("point_entries"))
  discard conn.execUpdate(
    """delete from rating.events
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(event.get.get("id"))])

proc revertSource*(db: Db, communityId, sourceId: string): int =
  var removed = 0
  db.tx(proc(conn: DbConn) =
    removed = revertSourceConn(conn, communityId, sourceId))
  removed

proc rebuildConn*(conn: DbConn, communityId: string,
                  params: RatingParams): IngestResult =
  ## Deterministic: events and counters are thrown away and recomputed from the
  ## approved sessions, then from the signed-off tournaments, so two runs always
  ## end at the same numbers. A rebuild must not erase a tournament that was
  ## ingested incrementally, so both source kinds are replayed here.
  lockCommunity(conn, communityId)
  # Keep the id of every event that has a source: a rebuild must not invalidate
  # a screen or audit row that already names it.
  var preserved = initTable[string, string]()
  for row in conn.query(
    """select event_type, source_id::text as source_id, id::text as id
       from rating.events
       where community_id = $1::uuid and source_id is not null""",
    @[textParam(communityId)]):
    preserved[row.get("event_type") & ":" & row.get("source_id")] = row.get("id")
  discard conn.execUpdate(
    """delete from rating.events where community_id = $1::uuid""",
    @[textParam(communityId)])
  discard conn.execUpdate(
    """delete from rating.player_state where community_id = $1::uuid""",
    @[textParam(communityId)])
  var ids: seq[string] = @[]
  for row in conn.query(
    """select id from session.sessions
       where community_id = $1::uuid and approved_at is not null
         and status in """ & approvedStatuses & """
       order by approved_at, id""",
    @[textParam(communityId)]):
    ids.add(row.get("id"))
  for sessionId in ids:
    let part = ingestSessionConn(conn, communityId, sessionId, params,
      preserved)
    result.events += part.events
    result.deltas += part.deltas
  let tournaments = ingestFinalTournamentsConn(conn, communityId, params,
    preserved)
  result.events += tournaments.events
  result.deltas += tournaments.deltas

proc rebuild*(db: Db, communityId: string, params: RatingParams): IngestResult =
  ## Wraps `rebuildConn` in a transaction. A caller that already holds one
  ## (a delete that must not leave half its work behind) uses `rebuildConn`.
  var outcome: IngestResult
  db.tx(proc(conn: DbConn) =
    outcome = rebuildConn(conn, communityId, params))
  outcome

proc removeEventConn*(conn: DbConn, communityId, eventId: string): int =
  ## Deletes one event by id on the caller's connection, leaving the caller to
  ## rebuild derived state, so the delete and the rebuild can share a boundary.
  let event = conn.queryOne(
    """select point_entries from rating.events
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(eventId)])
  if event.isNone:
    return 0
  result = parseInt(event.get.get("point_entries"))
  discard conn.execUpdate(
    """delete from rating.events
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(eventId)])

proc removeEvent*(db: Db, communityId, eventId: string): int =
  ## Deletes one event by id, leaving the caller to rebuild derived state.
  db.txRet(proc(conn: DbConn): int =
    removeEventConn(conn, communityId, eventId))
