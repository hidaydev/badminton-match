## Tournament ingest: one rating event per completed tournament.
##
## Ported from v1 `store/rating_extract.go` (extractClassicMatches and
## extractTeamMatches). A classic match is one game; a team partai is one game
## whose sides are the two players taking that partai's classes. The rally
## target follows the phase (30 in the group, 42 from the semifinal on), not
## `rating.score_target`, exactly like the v1 extractor.

import std/[options, strutils]
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

proc classicTarget(phase: string): int =
  if phase in ["sf", "3rd", "final"]: 42 else: 30

proc teamTarget(phase: string): int =
  if phase == "final": 42 else: 30

proc pairPlayers(conn: DbConn, communityId, pairId: string): seq[string] =
  let row = conn.queryOne(
    """select player_a_id::text as a, player_b_id::text as b
       from tournament.pairs where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(pairId)])
  if row.isSome:
    result.add(row.get.get("a"))
    result.add(row.get.get("b"))

proc classicGames(conn: DbConn, communityId, tournamentId: string):
    seq[TournamentGame] =
  for row in conn.query(
    """select m.match_key, m.phase, m.score_a, m.score_b, m.pair_a_id, m.pair_b_id
       from tournament.matches m
       where m.community_id = $1::uuid and m.tournament_id = $2::uuid
         and m.score_a is not null and m.score_b is not null
         and m.pair_a_id is not null and m.pair_b_id is not null
       order by m.match_order, m.match_key""",
    @[textParam(communityId), textParam(tournamentId)]):
    result.add(TournamentGame(
      key: row.get("match_key"),
      phase: row.get("phase"),
      target: classicTarget(row.get("phase")),
      scoreA: parseInt(row.get("score_a")),
      scoreB: parseInt(row.get("score_b")),
      sideA: pairPlayers(conn, communityId, row.get("pair_a_id")),
      sideB: pairPlayers(conn, communityId, row.get("pair_b_id"))))

proc partaiClasses(index: int): seq[string] =
  case index
  of 0: @["C+", "C"]
  of 1: @["A+", "A"]
  of 2: @["B+", "B"]
  else: @[]

proc teamSide(conn: DbConn, communityId, teamId: string,
              partaiIndex: int): seq[string] =
  ## A roster slot with no registered player contributes nothing; the other
  ## side keeps its points rather than voiding the partai.
  let classes = partaiClasses(partaiIndex)
  if classes.len == 0:
    return
  for row in conn.query(
    """select player_id::text as player_id from tournament.team_players
       where community_id = $1::uuid and team_id = $2::uuid and cls = any($3::text[])
       order by cls""",
    @[textParam(communityId), textParam(teamId),
      textParam("{" & classes.join(",") & "}")]):
    if row["player_id"].isSome:
      result.add(row.get("player_id"))

proc teamGames(conn: DbConn, communityId, tournamentId: string):
    seq[TournamentGame] =
  for match in conn.query(
    """select match_key, phase, team_a_id, team_b_id from tournament.team_matches
       where community_id = $1::uuid and tournament_id = $2::uuid
         and team_a_id is not null and team_b_id is not null
       order by match_order, match_key""",
    @[textParam(communityId), textParam(tournamentId)]):
    for partai in conn.query(
      """select partai_index, score_a, score_b from tournament.team_partai
         where community_id = $1::uuid and team_match_id = (
           select id from tournament.team_matches
           where community_id = $1::uuid and tournament_id = $2::uuid
             and match_key = $3)
           and score_a is not null and score_b is not null
         order by partai_index""",
      @[textParam(communityId), textParam(tournamentId),
        textParam(match.get("match_key"))]):
      let index = parseInt(partai.get("partai_index"))
      result.add(TournamentGame(
        key: match.get("match_key") & ":" & $index,
        phase: match.get("phase"),
        target: teamTarget(match.get("phase")),
        scoreA: parseInt(partai.get("score_a")),
        scoreB: parseInt(partai.get("score_b")),
        sideA: teamSide(conn, communityId, match.get("team_a_id"), index),
        sideB: teamSide(conn, communityId, match.get("team_b_id"), index)))

proc gamesFor*(conn: DbConn, communityId, tournamentId,
               format: string): seq[TournamentGame] =
  ## The scored games of one tournament, in bracket order. Ingest and the board
  ## share this, so a point can never come from a different game list than the
  ## ledger.
  if format == "team": teamGames(conn, communityId, tournamentId)
  else: classicGames(conn, communityId, tournamentId)

proc awardTournamentSide(conn: DbConn, communityId, eventId: string,
                         game: TournamentGame, teamA: bool, params: RatingParams,
                         population: float, deltas: var seq[DeltaRow]): int =
  let players = if teamA: game.sideA else: game.sideB
  if players.len == 0:
    return 0
  let opponents = if teamA: game.sideB else: game.sideA
  let margin = if teamA: game.scoreA - game.scoreB else: game.scoreB - game.scoreA
  let multiplier = opponentMultiplier(params,
    opponentAverage(conn, communityId, opponents), population)
  let points = gameValue(params.sessionBase, margin.float, game.target.float) *
    multiplier
  let delta = roundPoints(points)
  let letter = if teamA: "a" else: "b"
  for playerId in players:
    deltas.add(DeltaRow(side: letter, playerId: playerId, gameKey: game.key,
      delta: delta))
  # Between the two sides, so the other side's average sees this update.
  addState(conn, communityId, players, delta, won = margin > 0)
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
  let population = populationAverage(conn, communityId)
  var deltas: seq[DeltaRow] = @[]
  for game in games:
    result.deltas += awardTournamentSide(conn, communityId, eventId, game, true,
      params, population, deltas)
    result.deltas += awardTournamentSide(conn, communityId, eventId, game, false,
      params, population, deltas)
  # Deltas never feed a replay read, so the whole event is appended at once.
  writeDeltas(conn, communityId, eventId, deltas)

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
