import std/[json, options, strutils]
import db/db
import ../domain/rating

type
  IngestResult* = object
    events*: int
    deltas*: int

const
  approvedStatuses = "('locked', 'published', 'completed', 'archived')"

proc populationAverage*(conn: DbConn, communityId: string): float =
  let row = conn.queryOne(
    """select coalesce(avg(rating), 0)::float8 as average
       from rating.player_state where community_id = $1::uuid""",
    @[textParam(communityId)])
  if row.isSome: parseFloat(row.get.get("average")) else: 0.0

proc opponentAverage*(conn: DbConn, communityId: string,
                      players: seq[string]): float =
  if players.len == 0:
    return 0.0
  let row = conn.queryOne(
    """select coalesce(avg(rating), 0)::float8 as average
       from rating.player_state
       where community_id = $1::uuid and player_id = any($2::uuid[])""",
    @[textParam(communityId),
      textParam("{" & players.join(",") & "}")])
  if row.isSome: parseFloat(row.get.get("average")) else: 0.0

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

proc active(players, absent: seq[string]): seq[string] =
  for player in players:
    if player notin absent:
      result.add(player)

proc writeDelta*(conn: DbConn, communityId, eventId, side, playerId: string,
                 delta: int) =
  discard conn.execUpdate(
    """insert into rating.deltas
         (community_id, event_id, side, player_id, delta)
       values ($1::uuid, $2::uuid, $3, $4::uuid, $5)
       on conflict (event_id, side, player_id) do nothing""",
    @[textParam(communityId), textParam(eventId), textParam(side),
      textParam(playerId), intParam(delta.int64)])

proc upsertState*(conn: DbConn, communityId, playerId: string, delta: int,
                  won: bool) =
  discard conn.execUpdate(
    """insert into rating.player_state
         (community_id, player_id, rating, games_played, wins, losses)
       values ($1::uuid, $2::uuid, $3, 1, $4, $5)
       on conflict (community_id, player_id) do update set
         rating = rating.player_state.rating + excluded.rating,
         games_played = rating.player_state.games_played + 1,
         wins = rating.player_state.wins + excluded.wins,
         losses = rating.player_state.losses + excluded.losses,
         updated_at = now()""",
    @[textParam(communityId), textParam(playerId), intParam(delta.int64),
      intParam(if won: 1 else: 0), intParam(if won: 0 else: 1)])

proc awardSide(conn: DbConn, communityId, eventId: string, side, letter: string,
               margin: int, row: Row, absent: seq[string],
               population: float, params: RatingParams): int =
  let players = sidePlayers(row, side)
  let activePlayers = active(players, absent)
  if activePlayers.len == 0:
    return 0
  let multiplier = opponentMultiplier(params,
    opponentAverage(conn, communityId, activePlayers), population)
  let points = gameValue(params.sessionBase, margin.float,
    params.scoreTarget.float) * multiplier
  let delta = roundPoints(points)
  for playerId in activePlayers:
    writeDelta(conn, communityId, eventId, letter, playerId, delta)
    upsertState(conn, communityId, playerId, delta, won = margin > 0)
    inc result

proc ingestGame(conn: DbConn, communityId, eventId: string, params: RatingParams,
                row: Row, absent: seq[string], population: float): int =
  let scoreA = parseInt(row.get("score_a"))
  let scoreB = parseInt(row.get("score_b"))
  result += awardSide(conn, communityId, eventId, "side_a", "a",
    scoreA - scoreB, row, absent, population, params)
  result += awardSide(conn, communityId, eventId, "side_b", "b",
    scoreB - scoreA, row, absent, population, params)

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
  let population = populationAverage(conn, communityId)
  for row in conn.query(
    """select score_a, score_b,
              coalesce(side_a1::text, '') as side_a1,
              coalesce(side_a2::text, '') as side_a2,
              coalesce(side_b1::text, '') as side_b1,
              coalesce(side_b2::text, '') as side_b2
       from session.games
       where community_id = $1::uuid and session_id = $2::uuid
         and status = 'played' and score_a is not null and score_b is not null
       order by round_no, court_no""",
    @[textParam(communityId), textParam(sessionId)]):
    result.deltas += ingestGame(conn, communityId, eventId, params, row, absent,
      population)

proc ingestSession*(db: Db, communityId, sessionId: string,
                    params: RatingParams): IngestResult =
  ## Exactly one event per approved session; a second run is a no-op.
  var outcome: IngestResult
  discard db.tx(proc(conn: DbConn): int =
    outcome = ingestSessionConn(conn, communityId, sessionId, params)
    1)
  outcome

proc sourceFinalized*(db: Db, communityId, sourceId: string): bool =
  ## True when the source already has a signed-off event. The incremental paths
  ## (revert, ticker) must not touch it; only `rebuild` may, and it clears the
  ## flag because it recomputes every source from scratch.
  let row = db.queryOne(
    """select 1 as ok from rating.events
       where community_id = $1::uuid and source_id = $2::uuid and finalized""",
    @[textParam(communityId), textParam(sourceId)])
  row.isSome

proc eventFinalized*(db: Db, communityId, eventId: string): bool =
  let row = db.queryOne(
    """select 1 as ok from rating.events
       where community_id = $1::uuid and id = $2::uuid and finalized""",
    @[textParam(communityId), textParam(eventId)])
  row.isSome

proc setFinalized*(db: Db, communityId, eventId: string,
                   finalized: bool): Option[JsonNode] =
  ## Marks one event. The caller audits the change; the row is returned in the
  ## same shape as the rating-source list so the client can render it directly.
  let row = db.queryOne(
    """update rating.events
       set finalized = $3,
           finalized_at = case when $3 then now() else null end
       where community_id = $1::uuid and id = $2::uuid
       returning id, event_type, local_date::text as local_date,
                 coalesce(source_id::text, '') as source_id, finalized,
                 finalized_at::text as finalized_at""",
    @[textParam(communityId), textParam(eventId), boolParam(finalized)])
  if row.isNone:
    return none(JsonNode)
  let value = row.get
  some(%*{"id": value.get("id"), "type": value.get("event_type"),
    "date": value.get("local_date"), "sourceId": value.get("source_id"),
    "finalized": value.get("finalized") == "t",
    "finalizedAt": if value["finalized_at"].isSome:
      %value.get("finalized_at") else: newJNull()})

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
  ## sessions in date order, so two runs always end at the same numbers.
  var outcome: IngestResult
  discard db.tx(proc(conn: DbConn): int =
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
