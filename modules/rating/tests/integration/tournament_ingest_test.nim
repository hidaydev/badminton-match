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

proc deltaSum(sourceId, playerId: string): int =
  let row = database.queryOne(
    """select coalesce(sum(d.delta), 0)::int as total from rating.deltas d
       join rating.events e on e.id = d.event_id
       where d.community_id = $1::uuid and e.source_id = $2::uuid
         and d.player_id = $3::uuid""",
    @[textParam(communityId), textParam(sourceId), textParam(playerId)])
  if row.isSome: parseInt(row.get.get("total")) else: 0

proc totalDelta(playerId: string): int =
  let row = database.queryOne(
    """select coalesce(sum(delta), 0)::int as total from rating.deltas
       where community_id = $1::uuid and player_id = $2::uuid""",
    @[textParam(communityId), textParam(playerId)])
  if row.isSome: parseInt(row.get.get("total")) else: 0

proc playerRating(playerId: string): int =
  let row = database.queryOne(
    """select rating from rating.player_state
       where community_id = $1::uuid and player_id = $2::uuid""",
    @[textParam(communityId), textParam(playerId)])
  if row.isSome: parseInt(row.get.get("rating")) else: 0

proc eventCount(): int =
  let row = database.queryOne(
    """select count(*)::int as total from rating.events
       where community_id = $1::uuid""", @[textParam(communityId)])
  if row.isSome: parseInt(row.get.get("total")) else: 0

proc eventsFor(sourceId: string): int =
  let row = database.queryOne(
    """select count(*)::int as total from rating.events
       where community_id = $1::uuid and source_id = $2::uuid""",
    @[textParam(communityId), textParam(sourceId)])
  if row.isSome: parseInt(row.get.get("total")) else: 0

proc seedRating(playerId: string, rating: int) =
  discard database.execUpdate(
    """insert into rating.player_state (community_id, player_id, rating)
       values ($1::uuid, $2::uuid, $3)
       on conflict (community_id, player_id) do update set
         rating = excluded.rating, games_played = 0, wins = 0, losses = 0""",
    @[textParam(communityId), textParam(playerId), intParam(rating.int64)])

proc addPlayer(name: string): string =
  database.queryOne(
    """insert into player.players (community_id, canonical_name, gender)
       values ($1::uuid, $2, 'M') returning id""",
    @[textParam(communityId), textParam(name)]).get.get("id")

proc newSession(sessionPlayers: seq[string]): string =
  let id = database.queryOne(
    """insert into session.sessions
         (community_id, title, session_date, status, source, version,
          approved_at, approved_by)
       values ($1::uuid, 'Tour night', '2026-11-02', 'locked', 'manual', 1,
               now(), null)
       returning id""",
    @[textParam(communityId)]).get.get("id")
  for player in sessionPlayers:
    discard database.execUpdate(
      """insert into session.participants (community_id, session_id, player_id)
         values ($1::uuid, $2::uuid, $3::uuid)""",
      @[textParam(communityId), textParam(id), textParam(player)])
  discard database.execUpdate(
    """insert into session.games
         (community_id, session_id, round_no, court_no, score_a, score_b,
          status, side_a1, side_a2, side_b1, side_b2)
       values ($1::uuid, $2::uuid, 0, 0, 21, 15, 'played',
               $3::uuid, $4::uuid, $5::uuid, $6::uuid)""",
    @[textParam(communityId), textParam(id), textParam(sessionPlayers[0]),
      textParam(sessionPlayers[1]), textParam(sessionPlayers[2]),
      textParam(sessionPlayers[3])])
  id

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

  test "opponent strength comes from the other side":
    discard database.execUpdate(
      """delete from rating.player_state where community_id = $1::uuid""",
      @[textParam(communityId)])
    for index in 0 .. 1: seedRating(players[index], 300)
    for index in 2 .. 3: seedRating(players[index], 100)
    let tournamentId = newTournament("classic", "completed", "2026-11-03")
    let strong = newPair(tournamentId, "Strong", players[0], players[1])
    let weak = newPair(tournamentId, "Weak", players[2], players[3])
    addMatch(tournamentId, strong, weak, "group-A-0", "group", 30, 20)
    check setFinalized(database, communityId, tournamentId, true).isSome
    check ingestTournament(database, communityId, tournamentId,
      params()).status == tisOk
    # Population is 200. The strong side faces 100 (clamped to 0.5) and the
    # weak side faces the strong side's updated 303 (303/200). Using each
    # side's own average would award 10 and 2 instead.
    check deltaSum(tournamentId, players[0]) == 3
    check deltaSum(tournamentId, players[2]) == 5

  test "rebuild replays approved sessions and signed-off tournaments":
    let sessionPlayers = @[addPlayer("Rebuild S0"), addPlayer("Rebuild S1"),
      addPlayer("Rebuild S2"), addPlayer("Rebuild S3")]
    let sessionId = newSession(sessionPlayers)
    check ingestSession(database, communityId, sessionId,
      params()).events == 1
    let tournamentId = newTournament("classic", "completed", "2027-01-01")
    let pairA = newPair(tournamentId, "A", sessionPlayers[0],
      sessionPlayers[1])
    let pairB = newPair(tournamentId, "B", sessionPlayers[2],
      sessionPlayers[3])
    addMatch(tournamentId, pairA, pairB, "final-0", "final", 42, 35)
    check setFinalized(database, communityId, tournamentId, true).isSome
    check ingestTournament(database, communityId, tournamentId,
      params()).status == tisOk
    let before = eventCount()
    check eventsFor(sessionId) == 1
    check eventsFor(tournamentId) == 1
    let sessionDelta = deltaSum(sessionId, sessionPlayers[0])
    let tournamentDelta = deltaSum(tournamentId, sessionPlayers[0])
    check sessionDelta > 0
    check tournamentDelta > 0

    let rebuilt = rebuild(database, communityId, params())
    # Every approved session and signed-off tournament returns; the tournament
    # event is not silently dropped by the recompute.
    check rebuilt.events == before
    check eventCount() == before
    check eventsFor(sessionId) == 1
    check eventsFor(tournamentId) == 1
    check playerDeltas(sessionId) == 4
    check playerDeltas(tournamentId) == 4
    check deltaSum(sessionId, sessionPlayers[0]) > 0
    check deltaSum(tournamentId, sessionPlayers[0]) > 0
    # Player state is the ledger: the rating equals the deltas it survived on.
    for player in sessionPlayers:
      check playerRating(player) == totalDelta(player)
