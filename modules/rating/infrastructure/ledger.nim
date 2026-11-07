## The rating ledger's write primitives: events and the counters behind them.
## Session ingest, tournament ingest and the rebuild all write through here, so
## a played game is counted the same way everywhere.
##
## Points are not stored. The board projects them from the games on every read,
## and the stored per-game ledger that used to hold them fed only a second score
## nothing exposes any more. What remains is the tally: games, wins and losses.

import std/[options, tables]
import db/db

proc lockCommunity*(conn: DbConn, communityId: string) =
  ## Serialises every rating write for one community. Without it two ingests,
  ## or an ingest and a rebuild, can interleave their counter updates. The lock
  ## is transaction-scoped, so the caller must already be inside `db.tx`.
  discard conn.query(
    "select pg_advisory_xact_lock(hashtext('rating:' || $1::text))",
    @[textParam(communityId)])

proc addState*(conn: DbConn, communityId: string, playerIds: seq[string],
               won: bool) =
  ## One statement for a whole side, counting a played game and its outcome. A
  ## roster that lists the same player twice must still count twice, so a
  ## repeat is folded into a multiplicity instead of a second row, which
  ## ON CONFLICT DO UPDATE would reject.
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
         (community_id, player_id, games_played, wins, losses)
       select $1::uuid, t.player_id, t.repeats,
              $3::int * t.repeats, $4::int * t.repeats
       from unnest($2::uuid[], $5::int[]) as t(player_id, repeats)
       on conflict (community_id, player_id) do update set
         games_played = rating.player_state.games_played
           + excluded.games_played,
         wins = rating.player_state.wins + excluded.wins,
         losses = rating.player_state.losses + excluded.losses,
         updated_at = now()""",
    @[textParam(communityId), textParam(textArray(players)),
      intParam(if won: 1 else: 0), intParam(if won: 0 else: 1),
      textParam(textArray(counts))])

const finalizedSql* = """select 1 as ok from rating.sources
  where community_id = $1::uuid and source_id = $2::uuid and finalized"""

proc sourceFinalizedConn*(conn: DbConn, communityId, sourceId: string): bool =
  conn.queryOne(finalizedSql,
    @[textParam(communityId), textParam(sourceId)]).isSome