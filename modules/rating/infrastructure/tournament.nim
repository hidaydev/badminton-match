## Tournament ingest: one rating event per completed tournament.
##
## Ported from v1 `store/rating_extract.go` (extractClassicMatches and
## extractTeamMatches). A classic match is one game; a team partai is one game
## whose sides are the two players taking that partai's classes. The rally
## target follows the phase (30 in the group, 42 from the semifinal on), not
## `rating.score_target`, exactly like the v1 extractor.

import std/[options, strutils, tables]
import db/db
import ../domain/rating
import ./ledger

type
  TournamentIngestStatus* = enum
    tisOk = "ok"
    tisNotFound = "not found"
    tisNotFinal = "not final"

  TournamentIngestResult* = object
    status*: TournamentIngestStatus
    events*: int
    deltas*: int

  TournamentGame* = object
    ## One scored match (classic) or one scored partai (team) reduced to what
    ## the formula needs. The rally target comes from the phase, not from
    ## `rating.score_target`, exactly like v1. `key` keeps every game distinct
    ## inside the tournament's single rating event.
    key*: string
    phase*: string
    target*: int
    scoreA*, scoreB*: int
    sideA*, sideB*: seq[string]

  TeamPlayer = object
    ## One team roster slot: the class it plays and who fills it.
    cls: string
    playerId: string

proc classicTarget(phase: string): int =
  if phase in ["sf", "3rd", "final"]: 42 else: 30

proc teamTarget(phase: string): int =
  if phase == "final": 42 else: 30

proc pairPlayers(conn: DbConn, communityId: string,
                 pairIds: seq[string]): Table[string, seq[string]] =
  ## Every pair the tournament names, in one query: the board reads the games
  ## of a whole tournament, and a pair lookup per match made that linear in
  ## matches.
  if pairIds.len == 0:
    return
  for row in conn.query(
    """select id::text as id, coalesce(player_a_id::text, '') as a,
              coalesce(player_b_id::text, '') as b
       from tournament.pairs
       where community_id = $1::uuid and id = any($2::uuid[])""",
    @[textParam(communityId), textParam("{" & pairIds.join(",") & "}")]):
    result[row.get("id")] = @[row.get("a"), row.get("b")]

proc classicGames(conn: DbConn, communityId, tournamentId: string):
    seq[TournamentGame] =
  var rows: seq[Row] = @[]
  var pairIds: seq[string] = @[]
  for row in conn.query(
    """select m.match_key, m.phase, m.score_a, m.score_b, m.pair_a_id, m.pair_b_id
       from tournament.matches m
       where m.community_id = $1::uuid and m.tournament_id = $2::uuid
         and m.score_a is not null and m.score_b is not null
         and m.pair_a_id is not null and m.pair_b_id is not null
       order by m.match_order, m.match_key""",
    @[textParam(communityId), textParam(tournamentId)]):
    rows.add(row)
    for column in ["pair_a_id", "pair_b_id"]:
      let pairId = row.get(column)
      if pairId notin pairIds:
        pairIds.add(pairId)
  let pairs = pairPlayers(conn, communityId, pairIds)
  for row in rows:
    result.add(TournamentGame(
      key: row.get("match_key"),
      phase: row.get("phase"),
      target: classicTarget(row.get("phase")),
      scoreA: parseInt(row.get("score_a")),
      scoreB: parseInt(row.get("score_b")),
      sideA: pairs.getOrDefault(row.get("pair_a_id")),
      sideB: pairs.getOrDefault(row.get("pair_b_id"))))

proc partaiClasses*(index: int): seq[string] =
  case index
  of 0: @["C+", "C"]
  of 1: @["A+", "A"]
  of 2: @["B+", "B"]
  else: @[]

proc teamPlayers(conn: DbConn, communityId: string,
                 teamIds: seq[string]): Table[string, seq[TeamPlayer]] =
  ## Every roster of the tournament in one query. A roster slot with no
  ## registered player contributes nothing; the other side keeps its points
  ## rather than voiding the partai.
  if teamIds.len == 0:
    return
  for row in conn.query(
    """select team_id::text as team_id, cls, player_id::text as player_id
       from tournament.team_players
       where community_id = $1::uuid and team_id = any($2::uuid[])
         and player_id is not null
       order by team_id, cls""",
    @[textParam(communityId), textParam("{" & teamIds.join(",") & "}")]):
    result.mgetOrPut(row.get("team_id"), @[]).add(
      TeamPlayer(cls: row.get("cls"), playerId: row.get("player_id")))

proc teamSide(rosters: Table[string, seq[TeamPlayer]], teamId: string,
              partaiIndex: int): seq[string] =
  let classes = partaiClasses(partaiIndex)
  if classes.len == 0:
    return
  for entry in rosters.getOrDefault(teamId):
    if entry.cls in classes:
      result.add(entry.playerId)

proc teamGames(conn: DbConn, communityId, tournamentId: string):
    seq[TournamentGame] =
  var matches: seq[Row] = @[]
  var teamIds: seq[string] = @[]
  for match in conn.query(
    """select match_key, phase, team_a_id, team_b_id from tournament.team_matches
       where community_id = $1::uuid and tournament_id = $2::uuid
         and team_a_id is not null and team_b_id is not null
       order by match_order, match_key""",
    @[textParam(communityId), textParam(tournamentId)]):
    matches.add(match)
    for column in ["team_a_id", "team_b_id"]:
      let teamId = match.get(column)
      if teamId notin teamIds:
        teamIds.add(teamId)
  let teams = teamPlayers(conn, communityId, teamIds)
  var partais = initTable[string, seq[Row]]()
  for partai in conn.query(
    """select tm.match_key as match_key, p.partai_index, p.score_a, p.score_b
       from tournament.team_partai p
       join tournament.team_matches tm
         on tm.community_id = p.community_id and tm.id = p.team_match_id
       where p.community_id = $1::uuid and tm.tournament_id = $2::uuid
         and p.score_a is not null and p.score_b is not null
       order by tm.match_order, tm.match_key, p.partai_index""",
    @[textParam(communityId), textParam(tournamentId)]):
    partais.mgetOrPut(partai.get("match_key"), @[]).add(partai)
  for match in matches:
    for partai in partais.getOrDefault(match.get("match_key")):
      let index = parseInt(partai.get("partai_index"))
      result.add(TournamentGame(
        key: match.get("match_key") & ":" & $index,
        phase: match.get("phase"),
        target: teamTarget(match.get("phase")),
        scoreA: parseInt(partai.get("score_a")),
        scoreB: parseInt(partai.get("score_b")),
        sideA: teamSide(teams, match.get("team_a_id"), index),
        sideB: teamSide(teams, match.get("team_b_id"), index)))

proc gamesFor*(conn: DbConn, communityId, tournamentId,
               format: string): seq[TournamentGame] =
  ## The scored games of one tournament, in bracket order. Ingest and the board
  ## share this, so a point can never come from a different game list than the
  ## ledger.
  if format == "team": teamGames(conn, communityId, tournamentId)
  else: classicGames(conn, communityId, tournamentId)

proc awardTournamentSide(conn: DbConn, communityId: string,
                         game: TournamentGame, teamA: bool): int =
  let players = if teamA: game.sideA else: game.sideB
  if players.len == 0:
    return 0
  let margin = if teamA: game.scoreA - game.scoreB else: game.scoreB - game.scoreA
  addState(conn, communityId, players, won = margin > 0)
  players.len

proc ingestTournamentGames(conn: DbConn, communityId, tournamentId,
                           tournamentDate, format: string,
                           params: RatingParams): TournamentIngestResult =
  let games = gamesFor(conn, communityId, tournamentId, format)
  let event = conn.queryOne(
    """insert into rating.events (community_id, local_date, event_type, source_id)
       values ($1::uuid, $2::date, 'tournament', $3::uuid)
       returning id""",
    @[textParam(communityId), textParam(tournamentDate),
      textParam(tournamentId)])
  if event.isNone:
    return
  let eventId = event.get.get("id")
  result.events = 1
  for game in games:
    result.deltas += awardTournamentSide(conn, communityId, game, true)
    result.deltas += awardTournamentSide(conn, communityId, game, false)
  discard conn.execUpdate(
    """update rating.events set point_entries = $3::int
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(eventId),
      intParam(result.deltas.int64)])

proc ingestTournamentConn*(conn: DbConn, communityId, tournamentId: string,
                           params: RatingParams): TournamentIngestResult =
  ## One event per signed-off tournament, inside the caller's transaction.
  ## The gate is the source row's `finalized`, exactly like v1
  ## `rating_sources.finalized`.
  result.status = tisOk
  let header = conn.queryOne(
    """select status, format, event_date::text as event_date
       from tournament.tournaments
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(tournamentId)])
  if header.isNone:
    result.status = tisNotFound
    return
  # v1 gate: a tournament is only ingestable once its source is signed off,
  # so a running bracket cannot leak half a tournament into the board.
  if not sourceFinalizedConn(conn, communityId, tournamentId):
    result.status = tisNotFinal
    return
  let existing = conn.queryOne(
    """select id from rating.events
       where community_id = $1::uuid and event_type = 'tournament'
         and source_id = $2::uuid limit 1""",
    @[textParam(communityId), textParam(tournamentId)])
  if existing.isSome:
    return
  let part = ingestTournamentGames(conn, communityId, tournamentId,
    header.get.get("event_date"), header.get.get("format"), params)
  result.events = part.events
  result.deltas = part.deltas

proc ingestFinalTournamentsConn*(conn: DbConn, communityId: string,
                                 params: RatingParams):
    tuple[events, deltas: int] =
  ## Replays every signed-off tournament inside the caller's transaction. The
  ## rebuild clears the ledger first, so this is what keeps tournament points
  ## from disappearing on a full recompute.
  for row in conn.query(
    """select t.id::text as id from tournament.tournaments t
       join rating.sources s
         on s.community_id = t.community_id and s.source_id = t.id
       where t.community_id = $1::uuid and s.finalized
       order by t.event_date, t.id""",
    @[textParam(communityId)]):
    let part = ingestTournamentConn(conn, communityId, row.get("id"), params)
    result.events += part.events
    result.deltas += part.deltas

proc ingestTournament*(db: Db, communityId, tournamentId: string,
                       params: RatingParams): TournamentIngestResult =
  ## One event per signed-off tournament, serialised with every other rating
  ## write for the community.
  var outcome = TournamentIngestResult(status: tisOk)
  discard db.tx(proc(conn: DbConn): int =
    lockCommunity(conn, communityId)
    outcome = ingestTournamentConn(conn, communityId, tournamentId, params)
    1)
  outcome
