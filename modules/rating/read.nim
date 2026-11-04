import std/[json, options, strutils]
import db/db
import ./domain/rating

type
  BoardRow* = object
    playerId*: string
    name*: string
    tier*: string
    points*: int
    games*: int
    wins*: int
    losses*: int

proc boardRows(db: Db, communityId, asOf: string, params: RatingParams,
               limit: int): seq[BoardRow] =
  ## Points are the sum of the player's best entries inside the rolling window;
  ## only players with enough evidence reach the board, and the board is capped
  ## by `rank.board_limit`.
  for row in db.query(
    """with windowed as (
         select d.player_id, d.delta,
                row_number() over (partition by d.player_id
                                   order by d.delta desc, d.id) as rn
         from rating.deltas d
         join rating.events e on e.id = d.event_id
         where d.community_id = $1::uuid
           and e.local_date > $2::date - ($3::int * 7)
       )
       select p.id as player_id, p.canonical_name, coalesce(p.tier, '') as tier,
              coalesce(sum(w.delta), 0)::int as points,
              s.games_played, s.wins, s.losses
       from player.players p
       join rating.player_state s
         on s.community_id = p.community_id and s.player_id = p.id
       left join windowed w on w.player_id = p.id and w.rn <= $4
       where p.community_id = $1::uuid and s.games_played >= $5
       group by p.id, p.canonical_name, p.tier, s.games_played, s.wins, s.losses
       order by points desc, p.canonical_name asc
       limit $6""",
    @[textParam(communityId), textParam(asOf), intParam(params.windowWeeks.int64),
      intParam(params.bestN.int64), intParam(params.thinEvidenceN.int64),
      intParam(limit.int64)]):
    result.add(BoardRow(
      playerId: row.get("player_id"),
      name: row.get("canonical_name"),
      tier: row.get("tier"),
      points: parseInt(row.get("points")),
      games: parseInt(row.get("games_played")),
      wins: parseInt(row.get("wins")),
      losses: parseInt(row.get("losses"))))

proc board*(db: Db, communityId, asOf: string, params: RatingParams,
            limit: int): seq[BoardRow] =
  boardRows(db, communityId, asOf, params, limit)

proc boardEntry*(db: Db, communityId, playerId, asOf: string,
                 params: RatingParams, limit: int): Option[BoardRow] =
  ## One player's row plus its rank, resolved from the same board query so the
  ## detail view can never disagree with the list.
  let rows = boardRows(db, communityId, asOf, params, limit)
  for index, row in rows:
    if row.playerId == playerId:
      return some(row)
  none(BoardRow)

proc rankOf*(db: Db, communityId, playerId, asOf: string,
             params: RatingParams, limit: int): int =
  let rows = boardRows(db, communityId, asOf, params, limit)
  for index, row in rows:
    if row.playerId == playerId:
      return index + 1
  0

proc writeSnapshot*(db: Db, communityId, asOf: string,
                    rows: seq[BoardRow]): int =
  ## Daily snapshot of the board. Re-running on the same day overwrites the same
  ## rows instead of duplicating them.
  var written = 0
  discard db.tx(proc(conn: DbConn): int =
    for row in rows:
      written += conn.execUpdate(
        """insert into rating.snapshots
             (community_id, player_id, taken_on, rating)
           values ($1::uuid, $2::uuid, $3::date, $4)
           on conflict (community_id, player_id, taken_on) do update
             set rating = excluded.rating""",
        @[textParam(communityId), textParam(row.playerId), textParam(asOf),
          intParam(row.points.int64)])
    1)
  written

proc snapshotRows*(db: Db, communityId, asOf: string): seq[BoardRow] =
  for row in db.query(
    """select s.player_id, p.canonical_name, coalesce(p.tier, '') as tier,
              s.rating as points
       from rating.snapshots s
       join player.players p on p.id = s.player_id
       where s.community_id = $1::uuid and s.taken_on = $2::date
       order by s.rating desc, p.canonical_name asc""",
    @[textParam(communityId), textParam(asOf)]):
    result.add(BoardRow(playerId: row.get("player_id"), name: row.get("canonical_name"),
      tier: row.get("tier"), points: parseInt(row.get("points"))))

proc stats*(db: Db, communityId, playerId: string): Option[JsonNode] =
  ## Career numbers stay on player_state; the achievements list is a separate
  ## route so this stays one row.
  let row = db.queryOne(
    """select p.id, p.canonical_name, p.tier, p.gender,
              coalesce(s.games_played, 0) as games_played,
              coalesce(s.wins, 0) as wins, coalesce(s.losses, 0) as losses,
              coalesce(s.rating, 0) as rating
       from player.players p
       left join rating.player_state s
         on s.community_id = p.community_id and s.player_id = p.id
       where p.community_id = $1::uuid and p.id = $2::uuid""",
    @[textParam(communityId), textParam(playerId)])
  if row.isNone:
    return none(JsonNode)
  some(%*{
    "playerId": row.get.get("id"),
    "name": row.get.get("canonical_name"),
    "tier": if row.get["tier"].isNone: newJNull() else: %row.get.get("tier"),
    "gender": row.get.get("gender"),
    "points": parseInt(row.get.get("rating")),
    "games": parseInt(row.get.get("games_played")),
    "wins": parseInt(row.get.get("wins")),
    "losses": parseInt(row.get.get("losses")),
  })
