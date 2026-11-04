import std/[options, os, strutils, unittest]
import db/db
import ../../infrastructure/[ingest, tournament]
import ../../domain/rating

const slug = "touring-club"

proc dsn(): string = getEnv("MAJADU_PG_DSN")

if dsn().len == 0:
  echo "tournament ingest suite: skipped (MAJADU_PG_DSN is not set)"
  quit(0)

var
  database: Db
  communityId: string
  players: array[8, string]

proc cleanup() =
  ## FK-safe order for everything this suite may leave behind.
  for statement in [
    """delete from rating.deltas where community_id in
         (select id from platform.community where slug = 'touring-club')""",
    """delete from rating.events where community_id in
         (select id from platform.community where slug = 'touring-club')""",
    """delete from rating.sources where community_id in
         (select id from platform.community where slug = 'touring-club')""",
    """delete from rating.player_state where community_id in
         (select id from platform.community where slug = 'touring-club')""",
    """delete from tournament.team_partai where community_id in
         (select id from platform.community where slug = 'touring-club')""",
    """delete from tournament.team_matches where community_id in
         (select id from platform.community where slug = 'touring-club')""",
    """delete from tournament.team_players where community_id in
         (select id from platform.community where slug = 'touring-club')""",
    """delete from tournament.teams where community_id in
         (select id from platform.community where slug = 'touring-club')""",
    """delete from tournament.groups where community_id in
         (select id from platform.community where slug = 'touring-club')""",
    """delete from tournament.matches where community_id in
         (select id from platform.community where slug = 'touring-club')""",
    """delete from tournament.pairs where community_id in
         (select id from platform.community where slug = 'touring-club')""",
    """delete from tournament.tournaments where community_id in
         (select id from platform.community where slug = 'touring-club')""",
    """delete from session.games where community_id in
         (select id from platform.community where slug = 'touring-club')""",
    """delete from session.participants where community_id in
         (select id from platform.community where slug = 'touring-club')""",
    """delete from session.sessions where community_id in
         (select id from platform.community where slug = 'touring-club')""",
    """delete from player.claims where community_id in
         (select id from platform.community where slug = 'touring-club')""",
    """delete from player.players where community_id in
         (select id from platform.community where slug = 'touring-club')""",
    "delete from platform.community where slug = 'touring-club'",
    "delete from platform.user where google_sub like 'touring-%'"]:
    discard database.execUpdate(statement)

proc newTournament(format, status: string, date: string = "2026-11-01"): string =
  database.queryOne(
    """insert into tournament.tournaments
         (community_id, name, status, format, event_date)
       values ($1::uuid, 'Tour', $2, $3, $4::date) returning id""",
    @[textParam(communityId), textParam(status), textParam(format),
      textParam(date)]).get.get("id")

proc newPair(tournamentId: string, name: string, a, b: string): string =
  database.queryOne(
    """insert into tournament.pairs
         (community_id, tournament_id, display_name, player_a_id, player_b_id)
       values ($1::uuid, $2::uuid, $3, $4::uuid, $5::uuid) returning id""",
    @[textParam(communityId), textParam(tournamentId), textParam(name),
      textParam(a), textParam(b)]).get.get("id")

proc addMatch(tournamentId, pairA, pairB, key, phase: string,
              scoreA, scoreB: int) =
  discard database.execUpdate(
    """insert into tournament.matches
         (community_id, tournament_id, round_no, pair_a_id, pair_b_id,
          score_a, score_b, status, phase, match_key, match_order)
       values ($1::uuid, $2::uuid, 0, $3::uuid, $4::uuid, $5, $6, 'played',
               $7, $8, 0)""",
    @[textParam(communityId), textParam(tournamentId), textParam(pairA),
      textParam(pairB), intParam(scoreA.int64), intParam(scoreB.int64),
      textParam(phase), textParam(key)])

proc playerDeltas(eventSourceId: string): int =
  let row = database.queryOne(
    """select count(*)::int as total from rating.deltas d
       join rating.events e on e.id = d.event_id
       where d.community_id = $1::uuid and e.source_id = $2::uuid""",
    @[textParam(communityId), textParam(eventSourceId)])
  if row.isSome: parseInt(row.get.get("total")) else: 0

proc deltasFor(sourceId, playerId: string): int =
  let row = database.queryOne(
    """select count(*)::int as total from rating.deltas d
       join rating.events e on e.id = d.event_id
       where d.community_id = $1::uuid and e.source_id = $2::uuid
         and d.player_id = $3::uuid""",
    @[textParam(communityId), textParam(sourceId), textParam(playerId)])
  if row.isSome: parseInt(row.get.get("total")) else: 0

proc bootstrap() =
  database = openDb(dsn(), 1)
  cleanup()
  communityId = database.queryOne(
    """insert into platform.community (slug, name, timezone)
       values ($1, 'Touring Club', 'Asia/Jakarta') returning id""",
    @[textParam(slug)]).get.get("id")
  for index in 0 ..< players.len:
    players[index] = database.queryOne(
      """insert into player.players (community_id, canonical_name, gender)
         values ($1::uuid, $2, 'M') returning id""",
      @[textParam(communityId), textParam("Player " & $index)]).get.get("id")

proc params(): RatingParams =
  RatingParams(sessionBase: 10, scoreTarget: 21, opponentClampLow: 0.5,
    opponentClampHigh: 2, windowWeeks: 52, bestN: 10, thinEvidenceN: 3)

proc newTeam(tournamentId, name: string, seed: int): string =
  database.queryOne(
    """insert into tournament.teams
         (community_id, tournament_id, seed, team_name)
       values ($1::uuid, $2::uuid, $3, $4) returning id""",
    @[textParam(communityId), textParam(tournamentId), intParam(seed.int64),
      textParam(name)]).get.get("id")

proc addTeamPlayer(teamId, playerId, name, cls: string) =
  discard database.execUpdate(
    """insert into tournament.team_players
         (community_id, team_id, player_name, player_id, cls)
       values ($1::uuid, $2::uuid, $3, $4::uuid, $5)""",
    @[textParam(communityId), textParam(teamId), textParam(name),
      textParam(playerId), textParam(cls)])

bootstrap()

suite "tournament ingest":
  test "a signed-off classic tournament produces one event":
    let tournamentId = newTournament("classic", "completed")
    let pairA = newPair(tournamentId, "A", players[0], players[1])
    let pairB = newPair(tournamentId, "B", players[2], players[3])
    addMatch(tournamentId, pairA, pairB, "group-A-0", "group", 30, 20)
    check setFinalized(database, communityId, tournamentId, true).isSome
    let first = ingestTournament(database, communityId, tournamentId, params())
    check first.status == tisOk
    check first.events == 1
    check first.deltas == 4
    check playerDeltas(tournamentId) == 4
    let second = ingestTournament(database, communityId, tournamentId, params())
    check second.events == 0
    check playerDeltas(tournamentId) == 4

  test "a source that is not signed off is refused":
    let tournamentId = newTournament("classic", "draft")
    let pairA = newPair(tournamentId, "A", players[0], players[1])
    let pairB = newPair(tournamentId, "B", players[2], players[3])
    addMatch(tournamentId, pairA, pairB, "group-A-0", "group", 30, 20)
    let outcome = ingestTournament(database, communityId, tournamentId,
      params())
    check outcome.status == tisNotFinal
    check playerDeltas(tournamentId) == 0
    check setFinalized(database, communityId, tournamentId, true).isSome
    check ingestTournament(database, communityId, tournamentId,
      params()).status == tisOk
    check ingestTournament(database, communityId,
      "00000000-0000-0000-0000-000000000000", params()).status == tisNotFound

  test "a team partai scores only the classes that play it":
    let tournamentId = newTournament("team", "completed")
    check setFinalized(database, communityId, tournamentId, true).isSome
    let teamA = newTeam(tournamentId, "RED RAPTORS", 1)
    let teamB = newTeam(tournamentId, "WHITE FURY", 2)
    addTeamPlayer(teamA, players[0], "A0", "C+")
    addTeamPlayer(teamA, players[1], "A1", "C")
    addTeamPlayer(teamA, players[2], "A2", "A+")
    addTeamPlayer(teamA, players[3], "A3", "A")
    addTeamPlayer(teamB, players[4], "B0", "C+")
    addTeamPlayer(teamB, players[5], "B1", "C")
    addTeamPlayer(teamB, players[6], "B2", "A+")
    addTeamPlayer(teamB, players[7], "B3", "A")
    let matchId = database.queryOne(
      """insert into tournament.team_matches
           (community_id, tournament_id, phase, match_order, match_key,
            team_a_id, team_b_id)
         values ($1::uuid, $2::uuid, 'group', 0, 'g-1', $3::uuid, $4::uuid)
         returning id""",
      @[textParam(communityId), textParam(tournamentId), textParam(teamA),
        textParam(teamB)]).get.get("id")
    discard database.execUpdate(
      """insert into tournament.team_partai
           (community_id, team_match_id, partai_index, score_a, score_b)
         values ($1::uuid, $2::uuid, 0, 30, 24)""",
      @[textParam(communityId), textParam(matchId)])
    let outcome = ingestTournament(database, communityId, tournamentId,
      params())
    check outcome.status == tisOk
    check outcome.deltas == 4
    check deltasFor(tournamentId, players[0]) == 1
    check deltasFor(tournamentId, players[4]) == 1
    # A+ and A sit out this partai, so they gain nothing from it.
    check deltasFor(tournamentId, players[2]) == 0
    check deltasFor(tournamentId, players[6]) == 0
