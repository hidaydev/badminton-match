## Session reads: the header, who played, the games and their sets.
##
## The delivery layer renders these rows; it does not query them. A session read
## is four statements regardless of how many games it holds, because the sets of
## every game are aggregated in the same statement that reads the games. One
## query per game made the hottest member route and the public share payload
## scale with the result set instead of with the session.

import std/[json, options, tables]
import db/db
import ../lifecycle
import ../scoring

type
  Participant* = object
    playerId*: string
    name*: string
    absent*: bool

  GameSet* = object
    setNo*: int
    a*: int
    b*: int

  Game* = object
    roundNo*: int
    courtNo*: int
    status*: string
    winner*: string
    pointsA*: int
    pointsB*: int
    setsPlayed*: int
    setsA*: int
    setsB*: int
    sideA1*: string
    sideA2*: string
    sideB1*: string
    sideB2*: string
    sets*: seq[GameSet]

  Skip* = object
    roundNo*: int
    courtNo*: int
    playerId*: string

  SessionDetail* = object
    id*: string
    title*: string
    date*: string
    startTime*: string
    slotMinutes*: int
    status*: string
    version*: int
    rules*: ScoringRules
    participants*: seq[Participant]
    games*: seq[Game]
    skips*: seq[Skip]

proc gameKey(roundNo, courtNo: int): string =
  $roundNo & "-" & $courtNo

proc parseSets(node: JsonNode): seq[GameSet] =
  if node.kind != JArray:
    return @[]
  for entry in node:
    result.add(GameSet(
      setNo: entry["set"].getInt(),
      a: entry["a"].getInt(),
      b: entry["b"].getInt(),
    ))

proc gameFromRow(row: Row): Game =
  Game(
    roundNo: row.getInt("round_no"),
    courtNo: row.getInt("court_no"),
    status: row.get("status"),
    winner: row.get("winner"),
    pointsA: row.getInt("points_a"),
    pointsB: row.getInt("points_b"),
    setsPlayed: row.getInt("sets_played"),
    setsA: row.getInt("sets_a"),
    setsB: row.getInt("sets_b"),
    sideA1: row.get("side_a1"),
    sideA2: row.get("side_a2"),
    sideB1: row.get("side_b1"),
    sideB2: row.get("side_b2"),
    sets: parseSets(parseJson(row.get("sets"))),
  )

const
  gameColumns = """r.round_no, r.court_no, r.status, r.winner, r.points_a,
              r.points_b, r.sets_played, r.sets_a, r.sets_b,
              coalesce(r.side_a1::text, '') as side_a1,
              coalesce(r.side_a2::text, '') as side_a2,
              coalesce(r.side_b1::text, '') as side_b1,
              coalesce(r.side_b2::text, '') as side_b2,
              (select coalesce(jsonb_agg(jsonb_build_object(
                        'set', gs.set_no, 'a', gs.score_a, 'b', gs.score_b)
                        order by gs.set_no), '[]'::jsonb)
                 from session.game_sets gs
                where gs.community_id = r.community_id
                  and gs.session_id = r.session_id
                  and gs.round_no = r.round_no
                  and gs.court_no = r.court_no) as sets"""

proc setsByGame*(db: Db, communityId, sessionId: string):
    Table[string, seq[GameSet]] =
  ## Every set of every game in one statement, grouped by round and court. The
  ## anonymous share payload renders names, not ids, so it reads its games
  ## itself and merges these sets in.
  result = initTable[string, seq[GameSet]]()
  for row in db.query(
    """select round_no, court_no, set_no, score_a, score_b
       from session.game_sets
       where community_id = $1::uuid and session_id = $2::uuid
       order by round_no, court_no, set_no""",
    @[textParam(communityId), textParam(sessionId)]):
    let key = gameKey(row.getInt("round_no"), row.getInt("court_no"))
    result.mgetOrPut(key, @[]).add(GameSet(
      setNo: row.getInt("set_no"),
      a: row.getInt("score_a"),
      b: row.getInt("score_b"),
    ))

proc sets*[T](setsByGame: Table[string, seq[T]], roundNo, courtNo: int): seq[T] =
  ## The sets of one game from the table already loaded, never a new query.
  setsByGame.getOrDefault(gameKey(roundNo, courtNo), @[])

proc load*(db: Db, communityId, sessionId: string): Option[SessionDetail] =
  ## The whole session: header, participants, games with their sets, and skips.
  ## Four statements, whatever the number of games.
  let header = db.queryOne(
    """select id, title, session_date::text as session_date,
              to_char(start_time, 'HH24:MI') as start_time, slot_minutes,
              status, version, scoring_rules
       from session.sessions where id = $1 and community_id = $2""",
    @[textParam(sessionId), textParam(communityId)])
  if header.isNone:
    return none(SessionDetail)
  let row = header.get
  var detail = SessionDetail(
    id: row.get("id"),
    title: row.get("title"),
    date: row.get("session_date"),
    startTime: row.get("start_time"),
    slotMinutes: row.getInt("slot_minutes"),
    status: row.get("status"),
    version: row.getInt("version"),
    rules: parseSnapshotNode(parseJson(row.get("scoring_rules"))),
  )
  for entry in db.query(
    """select p.player_id, pl.canonical_name as name, p.is_absent
       from session.participants p
       join player.players pl on pl.id = p.player_id
       where p.community_id = $1::uuid and p.session_id = $2::uuid
       order by pl.canonical_name""",
    @[textParam(communityId), textParam(sessionId)]):
    detail.participants.add(Participant(
      playerId: entry.get("player_id"),
      name: entry.get("name"),
      absent: entry.getBool("is_absent"),
    ))
  for entry in db.query(
    """select """ & gameColumns & """
       from session.game_results r
       where r.community_id = $1::uuid and r.session_id = $2::uuid
       order by r.round_no, r.court_no""",
    @[textParam(communityId), textParam(sessionId)]):
    detail.games.add(gameFromRow(entry))
  for entry in db.query(
    """select round_no, court_no, player_id::text as player_id
       from session.game_skips
       where community_id = $1::uuid and session_id = $2::uuid
       order by round_no, court_no, player_id""",
    @[textParam(communityId), textParam(sessionId)]):
    detail.skips.add(Skip(
      roundNo: entry.getInt("round_no"),
      courtNo: entry.getInt("court_no"),
      playerId: entry.get("player_id"),
    ))
  some(detail)

proc loadGame*(db: Db, communityId, sessionId: string,
               roundNo, courtNo: int): Option[Game] =
  ## One match and its sets, in one statement.
  let row = db.queryOne(
    """select """ & gameColumns & """
       from session.game_results r
       where r.community_id = $1::uuid and r.session_id = $2::uuid
         and r.round_no = $3 and r.court_no = $4""",
    @[textParam(communityId), textParam(sessionId),
      intParam(roundNo.int64), intParam(courtNo.int64)])
  if row.isNone:
    return none(Game)
  some(gameFromRow(row.get))

proc exists*(db: Db, communityId, sessionId: string): bool =
  ## The id names a session of this community. A ticket is bound to the row, so
  ## a foreign-community id must answer 404 before anything is issued.
  db.queryOne(
    """select 1 as ok from session.sessions
       where id = $1::uuid and community_id = $2::uuid""",
    @[textParam(sessionId), textParam(communityId)]).isSome

proc inCommunitySlug*(db: Db, sessionId, slug: string): bool =
  ## A handshake names a ticket for a session and a community slug in the URL;
  ## the two must describe the same row.
  db.queryOne(
    """select 1 as ok from session.sessions s
       join platform.community c on c.id = s.community_id
       where s.id = $1::uuid and c.slug = $2""",
    @[textParam(sessionId), textParam(slug)]).isSome

proc gameResults*(db: Db, communityId, sessionId: string): seq[Row] =
  ## The public share payload: every game with its side names resolved in the
  ## same statement, so a whole group chat polling it does not cost a query per
  ## game.
  for row in db.query(
    """select r.round_no, r.court_no, r.status, r.winner,
              r.points_a, r.points_b, r.sets_played, r.sets_a, r.sets_b,
              coalesce(a1.canonical_name, '') as a1,
              coalesce(a2.canonical_name, '') as a2,
              coalesce(b1.canonical_name, '') as b1,
              coalesce(b2.canonical_name, '') as b2
       from session.game_results r
       left join player.players a1 on a1.id = r.side_a1
       left join player.players a2 on a2.id = r.side_a2
       left join player.players b1 on b1.id = r.side_b1
       left join player.players b2 on b2.id = r.side_b2
       where r.community_id = $1::uuid and r.session_id = $2::uuid
       order by r.round_no, r.court_no""",
    @[textParam(communityId), textParam(sessionId)]):
    result.add(row)

proc versionOf*(db: Db, communityId, sessionId: string): int =
  ## Zero means the id names no session in this community.
  let row = db.queryOne(
    """select version from session.sessions
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)])
  if row.isSome: row.get.getInt("version") else: 0

proc isApproved*(db: Db, communityId, sessionId: string): bool =
  ## An approval stamp with a status outside the approved set is not approved:
  ## this is the same two-column test the rating ledger applies.
  let row = db.queryOne(
    """select 1 as ok from session.sessions
       where community_id = $1::uuid and id = $2::uuid
         and approved_at is not null
         and status in """ & lifecycle.approvedStatuses,
    @[textParam(communityId), textParam(sessionId)])
  row.isSome

proc participantIds*(db: Db, communityId, sessionId: string): seq[string] =
  ## The players who took part in one session. A share code opens that session,
  ## so the public board it serves is this set and never the whole community.
  for row in db.query(
    """select player_id from session.participants
       where community_id = $1::uuid and session_id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)]):
    result.add(row.get("player_id"))
