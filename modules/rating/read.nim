import std/[algorithm, json, options, strutils, tables]
import db/db
import session/lifecycle
import tournament/domain/team
import ./domain/rating
import ./projection

type
  BreakdownEntry* = object
    ## One counted entry behind a board row: a session or a tournament. The
    ## points are the unrounded entry value, because the board rounds only the
    ## total it shows.
    sourceId*: Option[string]
    date*: string
    kind*: string
    points*: float
    games*: int

  BoardRow* = object
    rank*: int
    playerId*: string
    name*: string
    tier*: string
    points*: int
    games*: int
    wins*: int
    losses*: int
    prevRank*: Option[int]
    rankDelta*: Option[int]
    countedEntries*: int
    entriesAvailable*: int
    thinEvidence*: bool
    breakdown*: seq[BreakdownEntry]

  BoardQuery* = object
    ## Everything a board read needs. The tier filter is optional and empty
    ## means "no filter"; it is applied in SQL, never in the caller.
    communityId*: string
    asOf*: string
    params*: RatingParams
    limit*: int
    tier*: string
    ## Evidence floor; zero shows every player with an entry in the window.
    minSessions*: int
    ## Restricts the board to these players; empty means the whole community.
    ## A share link sets it so a forwarded code publishes one session, not the
    ## community's whole board.
    playerIds*: seq[string]

proc uuidArray(ids: seq[string]): string =
  "{" & ids.join(",") & "}"

proc boardRows(db: Db, query: BoardQuery): seq[BoardRow] =
  ## Points are the sum of the player's best entries inside the rolling window;
  ## every entry is one source, and the projection is the same one the player
  ## page reads, so a row can never disagree with its own detail. Players with
  ## no entry in the window are not on the board, exactly like v1.
  let projections = projection.project(db, query.communityId, query.asOf,
    query.params)
  for row in db.query(
    """select p.id as player_id, p.canonical_name, coalesce(p.tier, '') as tier,
              coalesce(s.games_played, 0) as games_played,
              coalesce(s.wins, 0) as wins, coalesce(s.losses, 0) as losses
       from player.players p
       left join rating.player_state s
         on s.community_id = p.community_id and s.player_id = p.id
       where p.community_id = $1::uuid
         and ($2::text = '' or coalesce(p.tier, '') = $2)
         and (cardinality($3::uuid[]) = 0 or p.id = any($3::uuid[]))""",
    @[textParam(query.communityId), textParam(query.tier),
      textParam(uuidArray(query.playerIds))]):
    let playerId = row.get("player_id")
    if not projections.hasKey(playerId):
      continue
    let projected = projections[playerId]
    if projected.available < query.minSessions:
      continue
    var breakdown: seq[BreakdownEntry] = @[]
    for entry in projected.entries[0 ..< projected.counted]:
      breakdown.add(BreakdownEntry(sourceId: some(entry.sourceId),
        date: entry.date, kind: entry.kind, points: entry.points,
        games: entry.games))
    result.add(BoardRow(
      playerId: playerId,
      name: row.get("canonical_name"),
      tier: row.get("tier"),
      points: projected.points,
      games: parseInt(row.get("games_played")),
      wins: parseInt(row.get("wins")),
      losses: parseInt(row.get("losses")),
      countedEntries: projected.counted,
      entriesAvailable: projected.available,
      thinEvidence: projected.thinEvidence,
      breakdown: breakdown))
  if result.len == 0:
    return
  result.sort(proc(a, b: BoardRow): int =
    if a.points != b.points: cmp(b.points, a.points)
    elif a.entriesAvailable != b.entriesAvailable:
      cmp(b.entriesAvailable, a.entriesAvailable)
    elif a.name != b.name: cmp(a.name, b.name)
    else: cmp(a.playerId, b.playerId))
  if query.limit > 0 and result.len > query.limit:
    result.setLen(query.limit)
  # Ties share a rank (1, 2, 2, 4), the same rule the v1 board used.
  for index in 0 ..< result.len:
    if index > 0 and result[index].points == result[index - 1].points:
      result[index].rank = result[index - 1].rank
    else:
      result[index].rank = index + 1
  # Movement against the most recent earlier snapshot that has rows. Ties share
  # a rank here too (1, 2, 2, 4), the rule the board applies, so two players on
  # the same points never read as movement in opposite directions.
  var previous = initTable[string, int]()
  for row in db.query(
    """with last as (
         select max(taken_on) as taken_on from rating.snapshots
         where community_id = $1::uuid and taken_on < $2::date
       )
       select s.player_id,
              (rank() over (order by s.rating desc))::int as prev_rank
       from rating.snapshots s
       join player.players p on p.id = s.player_id
       join last on s.taken_on = last.taken_on
       where s.community_id = $1::uuid""",
    @[textParam(query.communityId), textParam(query.asOf)]):
    previous[row.get("player_id")] = parseInt(row.get("prev_rank"))
  for row in result.mitems:
    if previous.hasKey(row.playerId):
      let before = previous[row.playerId]
      row.prevRank = some(before)
      row.rankDelta = some(before - row.rank)

proc latestEventDate*(db: Db, communityId: string): string =
  ## The board is anchored on the last rated event, not on today: a quiet week
  ## must not slide the window forward and silently drop old entries. The anchor
  ## never passes today either, because one event dated in the future would move
  ## the window with it and empty the board until that date arrives. Empty means
  ## the community has nothing rated yet.
  let row = db.queryOne(
    """select least(current_date, max(local_date))::text as day
       from rating.events
       where community_id = $1::uuid
       having max(local_date) is not null""",
    @[textParam(communityId)])
  if row.isSome and row.get["day"].isSome: row.get.get("day") else: ""

proc board*(db: Db, query: BoardQuery): seq[BoardRow] =
  boardRows(db, query)

proc boardEntry*(db: Db, query: BoardQuery,
                 playerId: string): Option[BoardRow] =
  ## One player's row plus its rank, resolved from the same board query so the
  ## detail view can never disagree with the list.
  let rows = boardRows(db, query)
  for row in rows:
    if row.playerId == playerId:
      return some(row)
  none(BoardRow)

proc rankOf*(db: Db, query: BoardQuery, playerId: string): int =
  let rows = boardRows(db, query)
  for row in rows:
    if row.playerId == playerId:
      return row.rank
  0

proc writeSnapshot*(db: Db, communityId, asOf: string,
                    rows: seq[BoardRow]): int =
  ## Daily snapshot of the board. Re-running on the same day overwrites the same
  ## rows instead of duplicating them, and the rank moves with the points so the
  ## stored placement can never disagree with the board it came from. A rank of
  ## zero means the caller had none to give, so the column stays NULL.
  var written = 0
  discard db.tx(proc(conn: DbConn): int =
    for row in rows:
      written += conn.execUpdate(
        """insert into rating.snapshots
             (community_id, player_id, taken_on, rating, rank)
           values ($1::uuid, $2::uuid, $3::date, $4, nullif($5, 0))
           on conflict (community_id, player_id, taken_on) do update
             set rating = excluded.rating, rank = excluded.rank""",
        @[textParam(communityId), textParam(row.playerId), textParam(asOf),
          intParam(row.points.int64), intParam(row.rank.int64)])
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

const playedGameFilter =
  """g.status = 'played' and g.winner <> ''"""

const approvedSessionFilter =
  """s.approved_at is not null
     and s.status in """ & approvedStatuses

const careerListCap = 3
  ## The career page shows a short top list, so each social tally stops at the
  ## three names that matter rather than the full ranking.

proc playerHistory(db: Db, communityId, playerId: string,
                   limit = 50): JsonNode =
  ## Recent played session games, newest first. Only an approved session is a
  ## record of a result, and a game the player skipped is not theirs at all.
  result = newJArray()
  for row in db.query(
    """select s.session_date::text as session_date, s.title,
              g.round_no, g.court_no, g.points_a, g.points_b, g.winner,
              coalesce((select json_agg(json_build_object(
                          'set', x.set_no, 'a', x.score_a, 'b', x.score_b)
                          order by x.set_no)
                        from session.game_sets x
                        where x.community_id = g.community_id
                          and x.session_id = g.session_id
                          and x.round_no = g.round_no
                          and x.court_no = g.court_no), '[]'::json) as sets,
              coalesce(g.side_a1::text, '') as a1,
              coalesce(g.side_a2::text, '') as a2,
              coalesce(g.side_b1::text, '') as b1,
              coalesce(g.side_b2::text, '') as b2,
              coalesce(pa1.canonical_name, '') as a1_name,
              coalesce(pa2.canonical_name, '') as a2_name,
              coalesce(pb1.canonical_name, '') as b1_name,
              coalesce(pb2.canonical_name, '') as b2_name
       from session.game_results g
       join session.sessions s
         on s.community_id = g.community_id and s.id = g.session_id
       left join player.players pa1 on pa1.id = g.side_a1
         and pa1.community_id = g.community_id
       left join player.players pa2 on pa2.id = g.side_a2
         and pa2.community_id = g.community_id
       left join player.players pb1 on pb1.id = g.side_b1
         and pb1.community_id = g.community_id
       left join player.players pb2 on pb2.id = g.side_b2
         and pb2.community_id = g.community_id
       where g.community_id = $1::uuid
         and (g.side_a1 = $2::uuid or g.side_a2 = $2::uuid
              or g.side_b1 = $2::uuid or g.side_b2 = $2::uuid)
         and """ & playedGameFilter & """
         and """ & approvedSessionFilter & """
         and not exists (
           select 1 from session.game_skips k
           where k.community_id = g.community_id
             and k.session_id = g.session_id
             and k.round_no = g.round_no and k.court_no = g.court_no
             and k.player_id = $2::uuid)
       order by s.session_date desc, s.id desc, g.round_no desc, g.court_no desc
       limit $3""",
    @[textParam(communityId), textParam(playerId), intParam(limit.int64)]):
    var teammates = newJArray()
    var opponents = newJArray()
    var onA = false
    if row.get("a1") == playerId or row.get("a2") == playerId:
      onA = true
      if row.get("a1") == playerId:
        if row.get("a2_name").len > 0: teammates.add(%row.get("a2_name"))
      else:
        if row.get("a1_name").len > 0: teammates.add(%row.get("a1_name"))
      for name in [row.get("b1_name"), row.get("b2_name")]:
        if name.len > 0: opponents.add(%name)
    else:
      if row.get("b1") == playerId:
        if row.get("b2_name").len > 0: teammates.add(%row.get("b2_name"))
      else:
        if row.get("b1_name").len > 0: teammates.add(%row.get("b1_name"))
      for name in [row.get("a1_name"), row.get("a2_name")]:
        if name.len > 0: opponents.add(%name)
    let pointsA = parseInt(row.get("points_a"))
    let pointsB = parseInt(row.get("points_b"))
    let won = if onA: row.get("winner") == "a" else: row.get("winner") == "b"
    result.add(%*{
      "date": row.get("session_date"),
      "title": row.get("title"),
      "gameRef": row.get("round_no") & "-" & row.get("court_no"),
      "outcome": if won: "W" else: "L",
      "scoreA": pointsA,
      "scoreB": pointsB,
      "sets": parseJson(row.get("sets")),
      "teammates": teammates,
      "opponents": opponents,
    })

proc playerSessions(db: Db, communityId, playerId: string,
                    limit = 100): JsonNode =
  ## The player's sessions, newest first. A player can have years of history,
  ## so the list is bounded rather than returned in full.
  result = newJArray()
  for row in db.query(
    """select s.id, s.session_date::text as session_date, s.title, p.is_absent
       from session.participants p
       join session.sessions s
         on s.community_id = p.community_id and s.id = p.session_id
       where p.community_id = $1::uuid and p.player_id = $2::uuid
       order by s.session_date desc, s.id desc
       limit $3""",
    @[textParam(communityId), textParam(playerId), intParam(limit.int64)]):
    result.add(%*{
      "id": row.get("id"),
      "date": row.get("session_date"),
      "title": row.get("title"),
      "absent": row.get("is_absent") == "t",
    })

proc playerSocial(db: Db, communityId, playerId: string,
                  opponentsOnly: bool): JsonNode =
  ## Partner and opponent counts over played session games, at most three names
  ## ordered by games together. The player's side decides both the teammate and
  ## the win flag. A player who skipped a game sat that game out, so it is
  ## neither theirs nor a partner or opponent of anyone else in it.
  result = newJArray()
  let gamesCte =
    """with games as (
         select g.id, g.community_id, g.session_id, g.round_no, g.court_no,
                (g.side_a1 = $2::uuid or g.side_a2 = $2::uuid) as on_a,
                (g.winner = 'a') as a_won,
                case when g.side_a1 = $2::uuid then g.side_a2
                     when g.side_a2 = $2::uuid then g.side_a1
                     when g.side_b1 = $2::uuid then g.side_b2
                     when g.side_b2 = $2::uuid then g.side_b1
                     else null end as mate,
                case when g.side_a1 = $2::uuid or g.side_a2 = $2::uuid
                     then array[g.side_b1, g.side_b2]
                     else array[g.side_a1, g.side_a2] end as opps
         from session.game_results g
         join session.sessions s
           on s.community_id = g.community_id and s.id = g.session_id
         where g.community_id = $1::uuid
           and (g.side_a1 = $2::uuid or g.side_a2 = $2::uuid
                or g.side_b1 = $2::uuid or g.side_b2 = $2::uuid)
           and """ & playedGameFilter & """
           and """ & approvedSessionFilter & """
           and not exists (
             select 1 from session.game_skips k
             where k.community_id = g.community_id
               and k.session_id = g.session_id
               and k.round_no = g.round_no and k.court_no = g.court_no
               and k.player_id = $2::uuid)
       )"""
  let sql =
    if opponentsOnly:
      gamesCte & """
       select p.canonical_name as name, count(*)::int as count,
              count(*) filter (where case when games.on_a then games.a_won
                                          else not games.a_won end)::int
                as wins,
              count(*) filter (where case when games.on_a then not games.a_won
                                          else games.a_won end)::int
                as losses
       from games
       cross join lateral unnest(games.opps) as opp(player_id)
       join player.players p on p.id = opp.player_id
         and p.community_id = $1::uuid
       where not exists (
         select 1 from session.game_skips k
         where k.community_id = games.community_id
           and k.session_id = games.session_id
           and k.round_no = games.round_no and k.court_no = games.court_no
           and k.player_id = opp.player_id)
       group by p.canonical_name
       order by count desc, p.canonical_name asc
       limit """ & $careerListCap
    else:
      gamesCte & """
       select p.canonical_name as name, count(*)::int as count,
              count(*) filter (where case when games.on_a then games.a_won
                                          else not games.a_won end)::int
                as wins,
              count(*) filter (where case when games.on_a then not games.a_won
                                          else games.a_won end)::int
                as losses
       from games
       join player.players p on p.id = games.mate
         and p.community_id = $1::uuid
       where games.mate is not null
         and not exists (
           select 1 from session.game_skips k
           where k.community_id = games.community_id
             and k.session_id = games.session_id
             and k.round_no = games.round_no and k.court_no = games.court_no
             and k.player_id = games.mate)
       group by p.canonical_name
       order by count desc, p.canonical_name asc
       limit """ & $careerListCap
  for row in db.query(sql, @[textParam(communityId), textParam(playerId)]):
    result.add(%*{
      "name": row.get("name"),
      "count": parseInt(row.get("count")),
      "wins": parseInt(row.get("wins")),
      "losses": parseInt(row.get("losses")),
    })

type
  CareerTally = tuple[count: int, wins: int]

  TeamRosterEntry = object
    cls: TeamClass
    name: string

  TeamFixture = object
    teamA: string
    teamB: string
    partaiIndex: int
    scoreA: int
    scoreB: int

  TeamMembership = object
    teamId: string
    cls: TeamClass
    partaiIndex: int

proc parseTeamClass(value: string): Option[TeamClass] =
  ## The database stores a class as the enum's own string, so the mapping stays
  ## in the tournament domain instead of being repeated as a second copy.
  try:
    some(parseEnum[TeamClass](value))
  except ValueError:
    none(TeamClass)

proc partaiIndexOf(cls: TeamClass): int =
  ## The one partai a class plays; PartaiClasses is the only place that says so.
  for index in 0 ..< PartaiClasses.len:
    if classInPartai(index, cls):
      return index
  -1

proc addTally(tallies: var Table[string, CareerTally], name: string, won: bool) =
  var tally = tallies.getOrDefault(name)
  tally.count.inc
  if won: tally.wins.inc
  tallies[name] = tally

proc rosterName(roster: seq[TeamRosterEntry], cls: TeamClass): Option[string] =
  ## A fixture is only trustworthy when exactly one rostered player holds the
  ## class; a missing or duplicated class would make the partner a guess.
  var found = 0
  var name = ""
  for entry in roster:
    if entry.cls == cls:
      found.inc
      name = entry.name
  if found == 1: some(name) else: none(string)

proc tournamentPartners(db: Db, communityId, playerId: string,
                        opponentsOnly: bool): JsonNode =
  ## Classic tournament pairs plus team-format partais, at most three names
  ## ordered by games together. A team event stores partais instead of pairs, so
  ## the class-to-partai mapping comes from the tournament domain: a rostered
  ## player appears in the partai that holds their class, partnered by the other
  ## class of that pair and facing both classes of the opposing team. The classic
  ## rows still come from SQL; the two tallies merge on the canonical name.
  result = newJArray()
  let classicCte =
    """with classic as (
         select case when pa.player_a_id = $2::uuid then pa.player_b_id
                     when pa.player_b_id = $2::uuid then pa.player_a_id
                     else null end as mate,
                (pa.player_a_id = $2::uuid or pa.player_b_id = $2::uuid)
                  as on_a,
                (m.score_a > m.score_b) as a_won,
                case when pa.player_a_id = $2::uuid
                       or pa.player_b_id = $2::uuid
                     then array[pb.player_a_id, pb.player_b_id]
                     else array[pa.player_a_id, pa.player_b_id] end as opps
         from tournament.matches m
         join tournament.tournaments t
           on t.community_id = m.community_id and t.id = m.tournament_id
          and t.format = 'classic'
         join tournament.pairs pa on pa.community_id = m.community_id
                                  and pa.id = m.pair_a_id
         join tournament.pairs pb on pb.community_id = m.community_id
                                  and pb.id = m.pair_b_id
         where m.community_id = $1::uuid
           and (pa.player_a_id = $2::uuid or pa.player_b_id = $2::uuid
                or pb.player_a_id = $2::uuid or pb.player_b_id = $2::uuid)
           and m.score_a is not null and m.score_b is not null
       )"""
  let sql =
    if opponentsOnly:
      classicCte & """
       select p.canonical_name as name, count(*)::int as count,
              count(*) filter (where case when classic.on_a then classic.a_won
                                          else not classic.a_won end)::int
                as wins
       from classic
       cross join lateral unnest(classic.opps) as opp(player_id)
       join player.players p on p.id = opp.player_id
         and p.community_id = $1::uuid
       group by p.canonical_name"""
    else:
      classicCte & """
       select p.canonical_name as name, count(*)::int as count,
              count(*) filter (where case when classic.on_a then classic.a_won
                                          else not classic.a_won end)::int
                as wins
       from classic
       join player.players p on p.id = classic.mate
         and p.community_id = $1::uuid
       where classic.mate is not null
       group by p.canonical_name"""
  var tallies = initTable[string, CareerTally]()
  for row in db.query(sql, @[textParam(communityId), textParam(playerId)]):
    tallies[row.get("name")] = (count: parseInt(row.get("count")),
      wins: parseInt(row.get("wins")))
  var members: seq[TeamMembership] = @[]
  var seenTeams = initTable[string, bool]()
  for row in db.query(
    """select team_id::text as team_id, cls
       from tournament.team_players
       where community_id = $1::uuid and player_id = $2::uuid""",
    @[textParam(communityId), textParam(playerId)]):
    let cls = parseTeamClass(row.get("cls"))
    if cls.isNone:
      continue
    let partaiIndex = partaiIndexOf(cls.get)
    if partaiIndex < 0:
      continue
    let teamId = row.get("team_id")
    if seenTeams.hasKey(teamId):
      continue
    seenTeams[teamId] = true
    members.add(TeamMembership(teamId: teamId, cls: cls.get,
      partaiIndex: partaiIndex))
  if members.len > 0:
    var membershipIds: seq[string] = @[]
    for member in members:
      if member.teamId notin membershipIds:
        membershipIds.add(member.teamId)
    var rosterIds = initTable[string, bool]()
    var rosterOrder: seq[string] = @[]
    for teamId in membershipIds:
      rosterIds[teamId] = true
      rosterOrder.add(teamId)
    var fixtures: seq[TeamFixture] = @[]
    for teamId in membershipIds:
      for row in db.query(
        """select tm.team_a_id::text as team_a_id,
                  tm.team_b_id::text as team_b_id,
                  part.partai_index, part.score_a::text as score_a,
                  part.score_b::text as score_b
           from tournament.team_partai part
           join tournament.team_matches tm
             on tm.community_id = part.community_id
            and tm.id = part.team_match_id
           where tm.community_id = $1::uuid
             and (tm.team_a_id = $2::uuid or tm.team_b_id = $2::uuid)
             and part.score_a is not null and part.score_b is not null""",
        @[textParam(communityId), textParam(teamId)]):
        let teamA = row.get("team_a_id")
        let teamB = row.get("team_b_id")
        for side in [teamA, teamB]:
          if not rosterIds.hasKey(side):
            rosterIds[side] = true
            rosterOrder.add(side)
        fixtures.add(TeamFixture(teamA: teamA, teamB: teamB,
          partaiIndex: parseInt(row.get("partai_index")),
          scoreA: parseInt(row.get("score_a")),
          scoreB: parseInt(row.get("score_b"))))
    var rosters = initTable[string, seq[TeamRosterEntry]]()
    for row in db.query(
      """select tp.team_id::text as team_id, tp.cls, p.canonical_name
         from tournament.team_players tp
         join player.players p
           on p.id = tp.player_id and p.community_id = tp.community_id
         where tp.community_id = $1::uuid
           and tp.team_id = any($2::uuid[])""",
      @[textParam(communityId), textParam(uuidArray(rosterOrder))]):
      let cls = parseTeamClass(row.get("cls"))
      if cls.isNone:
        continue
      rosters.mgetOrPut(row.get("team_id"), newSeq[TeamRosterEntry]()).add(
        TeamRosterEntry(cls: cls.get, name: row.get("canonical_name")))
    for member in members:
      let pair = PartaiClasses[member.partaiIndex]
      if opponentsOnly:
        for fixture in fixtures:
          if fixture.partaiIndex != member.partaiIndex:
            continue
          let onA = fixture.teamA == member.teamId
          if not onA and fixture.teamB != member.teamId:
            continue
          let oppRoster =
            rosters.getOrDefault(if onA: fixture.teamB else: fixture.teamA)
          let first = rosterName(oppRoster, pair[0])
          let second = rosterName(oppRoster, pair[1])
          if first.isNone or second.isNone:
            continue
          let won = if onA: fixture.scoreA > fixture.scoreB
                    else: fixture.scoreB > fixture.scoreA
          tallies.addTally(first.get, won)
          tallies.addTally(second.get, won)
      else:
        let partnerCls = if member.cls == pair[0]: pair[1] else: pair[0]
        let partner = rosterName(rosters.getOrDefault(member.teamId), partnerCls)
        if partner.isNone:
          continue
        for fixture in fixtures:
          if fixture.partaiIndex != member.partaiIndex:
            continue
          let onA = fixture.teamA == member.teamId
          if not onA and fixture.teamB != member.teamId:
            continue
          let won = if onA: fixture.scoreA > fixture.scoreB
                    else: fixture.scoreB > fixture.scoreA
          tallies.addTally(partner.get, won)
  var names: seq[string] = @[]
  for name in tallies.keys: names.add(name)
  names.sort(proc(a, b: string): int =
    let left = tallies[a]
    let right = tallies[b]
    if left.count != right.count: cmp(right.count, left.count)
    else: cmp(a, b))
  if names.len > careerListCap:
    names.setLen(careerListCap)
  for name in names:
    result.add(%*{
      "name": name,
      "count": tallies[name].count,
      "wins": tallies[name].wins,
    })

proc tournamentStats(db: Db, communityId, playerId: string): JsonNode =
  ## Games and wins per tournament from played classic matches and team
  ## team-matches. A team match counts once for a rostered player, with the win
  ## going to the team that took more scored partai.
  var games = initTable[string, int]()
  var wins = initTable[string, int]()
  for row in db.query(
    """with classic as (
         select m.tournament_id::text as tournament_id,
                case when pa.player_a_id = $2::uuid
                       or pa.player_b_id = $2::uuid
                     then m.score_a > m.score_b
                     else m.score_b > m.score_a end as won
         from tournament.matches m
         join tournament.pairs pa on pa.community_id = m.community_id
                                  and pa.id = m.pair_a_id
         join tournament.pairs pb on pb.community_id = m.community_id
                                  and pb.id = m.pair_b_id
         where m.community_id = $1::uuid
           and (pa.player_a_id = $2::uuid or pa.player_b_id = $2::uuid
                or pb.player_a_id = $2::uuid or pb.player_b_id = $2::uuid)
           and m.score_a is not null and m.score_b is not null
       )
       select tournament_id, count(*)::int as games,
              count(*) filter (where won)::int as wins
       from classic group by tournament_id""",
    @[textParam(communityId), textParam(playerId)]):
    let id = row.get("tournament_id")
    games[id] = parseInt(row.get("games"))
    wins[id] = parseInt(row.get("wins"))
  for row in db.query(
    """with team_matches as (
         select distinct tm.id, tm.community_id, tm.tournament_id,
                         tm.team_a_id, tm.team_b_id
         from tournament.team_matches tm
         join tournament.team_players tp on tp.community_id = tm.community_id
           and (tp.team_id = tm.team_a_id or tp.team_id = tm.team_b_id)
         where tm.community_id = $1::uuid and tp.player_id = $2::uuid
           and tm.team_a_id is not null and tm.team_b_id is not null
       ),
       scored as (
         select tm.tournament_id, tm.id,
                (tp.team_id = tm.team_a_id) as on_a,
                (select count(*) from tournament.team_partai part
                  where part.community_id = tm.community_id
                    and part.team_match_id = tm.id
                    and part.score_a is not null and part.score_b is not null
                    and part.score_a > part.score_b)::int as a_wins,
                (select count(*) from tournament.team_partai part
                  where part.community_id = tm.community_id
                    and part.team_match_id = tm.id
                    and part.score_a is not null and part.score_b is not null
                    and part.score_b > part.score_a)::int as b_wins
         from team_matches tm
         join tournament.team_players tp on tp.community_id = tm.community_id
           and (tp.team_id = tm.team_a_id or tp.team_id = tm.team_b_id)
         where tp.player_id = $2::uuid
       )
       select tournament_id::text as tournament_id, count(*)::int as games,
              count(*) filter (where (on_a and a_wins > b_wins)
                                  or (not on_a and b_wins > a_wins))::int
                as wins
       from scored
       where a_wins + b_wins > 0
       group by tournament_id""",
    @[textParam(communityId), textParam(playerId)]):
    let id = row.get("tournament_id")
    games[id] = games.getOrDefault(id) + parseInt(row.get("games"))
    wins[id] = wins.getOrDefault(id) + parseInt(row.get("wins"))
  var items = newJArray()
  var totalGames = 0
  var totalWins = 0
  for id, count in games:
    totalGames += count
    totalWins += wins.getOrDefault(id)
  if games.len > 0:
    var ids: seq[string] = @[]
    for id in games.keys: ids.add(id)
    for row in db.query(
      """select id::text as id, name, event_date::text as event_date
         from tournament.tournaments
         where community_id = $1::uuid and id = any($2::uuid[])
         order by event_date desc, name asc""",
      @[textParam(communityId), textParam(uuidArray(ids))]):
      let id = row.get("id")
      let count = games.getOrDefault(id)
      let won = wins.getOrDefault(id)
      items.add(%*{
        "id": id,
        "name": row.get("name"),
        "date": row.get("event_date"),
        "games": count,
        "wins": won,
        "losses": count - won,
      })
  %*{
    "gamesPlayed": totalGames,
    "wins": totalWins,
    "losses": totalGames - totalWins,
    "tournaments": items,
    "topPartners": tournamentPartners(db, communityId, playerId, false),
    "topOpponents": tournamentPartners(db, communityId, playerId, true),
  }

proc stats*(db: Db, communityId, playerId: string): Option[JsonNode] =
  ## The counters (`games`, `wins`, `losses`) stay on player_state because they
  ## are counts, not a score. `points` is deliberately absent: the only points
  ## number the API exposes is the board row, so the caller injects it from
  ## `boardEntry` instead of letting a second, accumulated rating disagree with
  ## the leaderboard. History, sessions and social tallies are read here because
  ## they share the player identity and are always requested together.
  let row = db.queryOne(
    """select p.id, p.canonical_name, p.tier, p.gender,
              coalesce(s.games_played, 0) as games_played,
              coalesce(s.wins, 0) as wins, coalesce(s.losses, 0) as losses
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
    "games": parseInt(row.get.get("games_played")),
    "wins": parseInt(row.get.get("wins")),
    "losses": parseInt(row.get.get("losses")),
    "history": playerHistory(db, communityId, playerId),
    "sessions": playerSessions(db, communityId, playerId),
    "topPartners": playerSocial(db, communityId, playerId, false),
    "topOpponents": playerSocial(db, communityId, playerId, true),
    "tournamentStats": tournamentStats(db, communityId, playerId),
  })
