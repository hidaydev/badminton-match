## The rating ledger's write primitives: event rows are appended, deltas are
## summed into player state. Session ingest, tournament ingest and the rebuild
## all write through these, so a point is computed the same way everywhere.

import std/[options, strutils, tables]
import db/db

type
  DeltaRow* = object
    ## One player's point from one game of one event. A whole event is written
    ## in one statement, so the batch carries the side and the game of each row.
    side*, playerId*, gameKey*: string
    delta*: int

proc textArray(values: seq[string]): string =
  ## An array literal that survives a comma, a brace or a quote inside a value
  ## (a match key is free text), unlike a bare join.
  var quoted: seq[string] = @[]
  for value in values:
    quoted.add("\"" & value.replace("\\", "\\\\").replace("\"", "\\\"") & "\"")
  "{" & quoted.join(",") & "}"

proc lockCommunity*(conn: DbConn, communityId: string) =
  ## Serialises every rating write for one community. Without it two ingests
  ## read the same population average and both append deltas, and a rebuild can
  ## interleave with an ingest. The lock is transaction-scoped, so the caller
  ## must already be inside `db.tx`.
  discard conn.query(
    "select pg_advisory_xact_lock(hashtext('rating:' || $1::text))",
    @[textParam(communityId)])

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

proc writeDeltas*(conn: DbConn, communityId, eventId: string,
                  rows: seq[DeltaRow]) =
  ## One statement per event instead of one per player. The conflict target is
  ## untouched, so replaying the same event still adds no second row.
  if rows.len == 0:
    return
  var sides, players, keys, deltas: seq[string] = @[]
  for row in rows:
    sides.add(row.side)
    players.add(row.playerId)
    keys.add(row.gameKey)
    deltas.add($row.delta)
  discard conn.execUpdate(
    """insert into rating.deltas
         (community_id, event_id, side, player_id, game_key, delta)
       select $1::uuid, $2::uuid, t.side, t.player_id, t.game_key, t.delta
       from unnest($3::text[], $4::uuid[], $5::text[], $6::int[])
         as t(side, player_id, game_key, delta)
       on conflict (event_id, side, player_id, game_key) do nothing""",
    @[textParam(communityId), textParam(eventId), textParam(textArray(sides)),
      textParam(textArray(players)), textParam(textArray(keys)),
      textParam(textArray(deltas))])

proc addState*(conn: DbConn, communityId: string, playerIds: seq[string],
               delta: int, won: bool) =
  ## One statement for a whole side. A roster that lists the same player twice
  ## must still count twice, so a repeat is folded into a multiplicity instead
  ## of a second row, which ON CONFLICT DO UPDATE would reject.
  if playerIds.len == 0:
    return
  var order: seq[string] = @[]
  var repeats = initTable[string, int]()
  for playerId in playerIds:
    if repeats.hasKeyOrPut(playerId, 1):
      repeats[playerId] = repeats[playerId] + 1
    else:
      order.add(playerId)
  var players, counts: seq[string] = @[]
  for playerId in order:
    players.add(playerId)
    counts.add($repeats[playerId])
  discard conn.execUpdate(
    """insert into rating.player_state
         (community_id, player_id, rating, games_played, wins, losses)
       select $1::uuid, t.player_id, $3::int * t.repeats, t.repeats,
              $4::int * t.repeats, $5::int * t.repeats
       from unnest($2::uuid[], $6::int[]) as t(player_id, repeats)
       on conflict (community_id, player_id) do update set
         rating = rating.player_state.rating + excluded.rating,
         games_played = rating.player_state.games_played
           + excluded.games_played,
         wins = rating.player_state.wins + excluded.wins,
         losses = rating.player_state.losses + excluded.losses,
         updated_at = now()""",
    @[textParam(communityId), textParam(textArray(players)),
      intParam(delta.int64), intParam(if won: 1 else: 0),
      intParam(if won: 0 else: 1), textParam(textArray(counts))])

const finalizedSql* = """select 1 as ok from rating.sources
  where community_id = $1::uuid and source_id = $2::uuid and finalized"""

proc sourceFinalizedConn*(conn: DbConn, communityId, sourceId: string): bool =
  conn.queryOne(finalizedSql,
    @[textParam(communityId), textParam(sourceId)]).isSome