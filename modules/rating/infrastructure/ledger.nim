## The rating ledger's write primitives: event rows are appended, deltas are
## summed into player state. Session ingest, tournament ingest and the rebuild
## all write through these, so a point is computed the same way everywhere.

import std/[options, strutils]
import db/db

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

proc writeDelta*(conn: DbConn, communityId, eventId, side, playerId, gameKey: string,
                 delta: int) =
  discard conn.execUpdate(
    """insert into rating.deltas
         (community_id, event_id, side, player_id, game_key, delta)
       values ($1::uuid, $2::uuid, $3, $4::uuid, $5, $6)
       on conflict (event_id, side, player_id, game_key) do nothing""",
    @[textParam(communityId), textParam(eventId), textParam(side),
      textParam(playerId), textParam(gameKey), intParam(delta.int64)])

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

const finalizedSql* = """select 1 as ok from rating.sources
  where community_id = $1::uuid and source_id = $2::uuid and finalized"""

proc sourceFinalizedConn*(conn: DbConn, communityId, sourceId: string): bool =
  conn.queryOne(finalizedSql,
    @[textParam(communityId), textParam(sourceId)]).isSome