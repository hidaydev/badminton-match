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
import ./ingest

type
  TournamentIngestStatus* = enum
    tisOk = "ok"
    tisNotFound = "not found"
    tisNotFinal = "not final"

  TournamentIngestResult* = object
    status*: TournamentIngestStatus
    events*: int
    deltas*: int

  TournamentGame = object
    ## One scored match (classic) or one scored partai (team) reduced to what
    ## the formula needs. The rally target comes from the phase, not from
    ## `rating.score_target`, exactly like v1.
    target: int
    scoreA, scoreB: int
    sideA, sideB: seq[string]

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
        target: teamTarget(match.get("phase")),
        scoreA: parseInt(partai.get("score_a")),
        scoreB: parseInt(partai.get("score_b")),
        sideA: teamSide(conn, communityId, match.get("team_a_id"), index),
        sideB: teamSide(conn, communityId, match.get("team_b_id"), index)))

proc awardTournamentSide(conn: DbConn, communityId, eventId: string,
                         game: TournamentGame, teamA: bool, params: RatingParams,
                         population: float): int =
  let players = if teamA: game.sideA else: game.sideB
  if players.len == 0:
    return 0
  let margin = if teamA: game.scoreA - game.scoreB else: game.scoreB - game.scoreA
  let multiplier = opponentMultiplier(params,
    opponentAverage(conn, communityId, players), population)
  let points = gameValue(params.sessionBase, margin.float, game.target.float) *
    multiplier
  let delta = roundPoints(points)
  let letter = if teamA: "a" else: "b"
  for playerId in players:
    writeDelta(conn, communityId, eventId, letter, playerId, delta)
    upsertState(conn, communityId, playerId, delta, won = margin > 0)
    inc result

proc ingestTournamentGames(conn: DbConn, communityId, tournamentId,
                           tournamentDate, format: string,
                           params: RatingParams): TournamentIngestResult =
  let games =
    if format == "team": teamGames(conn, communityId, tournamentId)
    else: classicGames(conn, communityId, tournamentId)
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
  for game in games:
    result.deltas += awardTournamentSide(conn, communityId, eventId, game, true,
      params, population)
    result.deltas += awardTournamentSide(conn, communityId, eventId, game, false,
      params, population)

proc ingestTournament*(db: Db, communityId, tournamentId: string,
                       params: RatingParams): TournamentIngestResult =
  ## One event per completed tournament. A tournament that is not finished is
  ## refused rather than partially ingested, mirroring v1's "final" gate (v2
  ## has no separate source row, so the status carries it).
  var outcome = TournamentIngestResult(status: tisOk)
  discard db.tx(proc(conn: DbConn): int =
    let header = conn.queryOne(
      """select status, format, event_date::text as event_date
         from tournament.tournaments
         where community_id = $1::uuid and id = $2::uuid""",
      @[textParam(communityId), textParam(tournamentId)])
    if header.isNone:
      outcome.status = tisNotFound
      return 0
    if header.get.get("status") notin ["completed", "archived"]:
      outcome.status = tisNotFinal
      return 0
    let existing = conn.queryOne(
      """select id from rating.events
         where community_id = $1::uuid and event_type = 'tournament'
           and source_id = $2::uuid limit 1""",
      @[textParam(communityId), textParam(tournamentId)])
    if existing.isSome:
      return 0
    let part = ingestTournamentGames(conn, communityId, tournamentId,
      header.get.get("event_date"), header.get.get("format"), params)
    outcome.events = part.events
    outcome.deltas = part.deltas
    1)
  outcome
