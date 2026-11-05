import std/[json, options, strutils, tables]
import db/db
import ../domain/rating
import ./ledger
import ./tournament

type
  IngestResult* = object
    events*: int
    deltas*: int

const
  approvedStatuses = "('locked', 'published', 'completed', 'archived')"

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

proc awardSide(conn: DbConn, communityId, eventId, gameKey: string,
               side, letter: string, margin: int, otherSide: string,
               row: Row, absent, skipped: seq[string], population: float,
               params: RatingParams): int =
  let players = sidePlayers(row, side)
  let activePlayers = active(players, absent, skipped)
  if activePlayers.len == 0:
    return 0
  let multiplier = opponentMultiplier(params,
    opponentAverage(conn, communityId,
      active(sidePlayers(row, otherSide), absent, skipped)),
    population)
  let points = gameValue(params.sessionBase, margin.float,
    params.scoreTarget.float) * multiplier
  let delta = roundPoints(points)
  for playerId in activePlayers:
    writeDelta(conn, communityId, eventId, letter, playerId, gameKey, delta)
    upsertState(conn, communityId, playerId, delta, won = margin > 0)
    inc result

proc ingestGame(conn: DbConn, communityId, eventId: string, params: RatingParams,
                row: Row, absent, skipped: seq[string],
                population: float): int =
  ## v1's gate: a game needs a real present player on both sides, but a side
  ## whose players were all substituted still keeps the game alive for the
  ## other side. Skipped players are present; absent ones are not.
  let sideA = sidePlayers(row, "side_a")
  let sideB = sidePlayers(row, "side_b")
  let presentA = active(sideA, absent, newSeq[string]())
  let presentB = active(sideB, absent, newSeq[string]())
  if presentA.len == 0 or presentB.len == 0:
    return 0
  let scoreA = parseInt(row.get("score_a"))
  let scoreB = parseInt(row.get("score_b"))
  let gameKey = row.get("round_no") & "-" & row.get("court_no")
  result += awardSide(conn, communityId, eventId, gameKey, "side_a", "a",
    scoreA - scoreB, "side_b", row, absent, skipped, population, params)
  result += awardSide(conn, communityId, eventId, gameKey, "side_b", "b",
    scoreB - scoreA, "side_a", row, absent, skipped, population, params)

proc ingestSessionConn(conn: DbConn, communityId, sessionId: string,
                       params: RatingParams): IngestResult =
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
  if session.isNone or session.get["approved_at"].isNone:
    return
  if session.get.get("status") notin ["locked", "published", "completed", "archived"]:
    return
  let event = conn.queryOne(
    """insert into rating.events (community_id, local_date, event_type, source_id)
       values ($1::uuid, $2::date, 'session', $3::uuid)
       returning id""",
    @[textParam(communityId), textParam(session.get.get("session_date")),
      textParam(sessionId)])
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
  let population = populationAverage(conn, communityId)
  for row in conn.query(
    """select round_no, court_no, score_a, score_b,
              coalesce(side_a1::text, '') as side_a1,
              coalesce(side_a2::text, '') as side_a2,
              coalesce(side_b1::text, '') as side_b1,
              coalesce(side_b2::text, '') as side_b2
       from session.games
       where community_id = $1::uuid and session_id = $2::uuid
         and status = 'played' and score_a is not null and score_b is not null
       order by round_no, court_no""",
    @[textParam(communityId), textParam(sessionId)]):
    let skipped = skipRows.getOrDefault(
      row.get("round_no") & "-" & row.get("court_no"))
    result.deltas += ingestGame(conn, communityId, eventId, params, row, absent,
      skipped, population)

proc ingestSession*(db: Db, communityId, sessionId: string,
                    params: RatingParams): IngestResult =
  ## Exactly one event per approved session; a second run is a no-op.
  var outcome: IngestResult
  discard db.tx(proc(conn: DbConn): int =
    lockCommunity(conn, communityId)
    outcome = ingestSessionConn(conn, communityId, sessionId, params)
    1)
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

proc dropSource*(db: Db, communityId, sourceId: string): int =
  ## Deletes the sign-off row for a source that itself is being deleted, so a
  ## later source reusing the id cannot inherit an old decision.
  db.execUpdate(
    """delete from rating.sources
       where community_id = $1::uuid and source_id = $2::uuid""",
    @[textParam(communityId), textParam(sourceId)])

proc revertSource*(db: Db, communityId, sourceId: string): int =
  ## Drops one source's event and its deltas. The caller rebuilds the derived
  ## state, because wins and losses cannot be recomputed from deltas alone.
  var removed = 0
  discard db.tx(proc(conn: DbConn): int =
    let event = conn.queryOne(
      """select id from rating.events
         where community_id = $1::uuid and source_id = $2::uuid""",
      @[textParam(communityId), textParam(sourceId)])
    if event.isNone:
      return 0
    let eventId = event.get.get("id")
    removed = conn.execUpdate(
      """delete from rating.deltas
         where community_id = $1::uuid and event_id = $2::uuid""",
      @[textParam(communityId), textParam(eventId)])
    discard conn.execUpdate(
      """delete from rating.events
         where community_id = $1::uuid and id = $2::uuid""",
      @[textParam(communityId), textParam(eventId)])
    1)
  removed

proc rebuild*(db: Db, communityId: string, params: RatingParams): IngestResult =
  ## Deterministic: the state is thrown away and recomputed from the approved
  ## sessions, then from the signed-off tournaments, so two runs always end at
  ## the same numbers. A rebuild must not erase a tournament that was ingested
  ## incrementally, so both source kinds are replayed here.
  var outcome: IngestResult
  discard db.tx(proc(conn: DbConn): int =
    lockCommunity(conn, communityId)
    discard conn.execUpdate(
      """delete from rating.deltas where community_id = $1::uuid""",
      @[textParam(communityId)])
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
         order by session_date, id""",
      @[textParam(communityId)]):
      ids.add(row.get("id"))
    for sessionId in ids:
      let part = ingestSessionConn(conn, communityId, sessionId, params)
      outcome.events += part.events
      outcome.deltas += part.deltas
    let tournaments = ingestFinalTournamentsConn(conn, communityId, params)
    outcome.events += tournaments.events
    outcome.deltas += tournaments.deltas
    1)
  outcome

proc removeEvent*(db: Db, communityId, eventId: string): int =
  ## Deletes one event by id, leaving the caller to rebuild derived state.
  var removed = 0
  discard db.tx(proc(conn: DbConn): int =
    removed = conn.execUpdate(
      """delete from rating.deltas
         where community_id = $1::uuid and event_id = $2::uuid""",
      @[textParam(communityId), textParam(eventId)])
    discard conn.execUpdate(
      """delete from rating.events
         where community_id = $1::uuid and id = $2::uuid""",
      @[textParam(communityId), textParam(eventId)])
    1)
  removed
