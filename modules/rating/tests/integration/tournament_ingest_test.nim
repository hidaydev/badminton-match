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

proc pointEntriesFor(sourceId: string): int =
  ## The event keeps how many player-game entries it produced, so a test can
  ## assert the ingest covered every game without reading a per-game ledger.
  let row = database.queryOne(
    """select coalesce(sum(point_entries), 0)::int as total from rating.events
       where community_id = $1::uuid and source_id = $2::uuid""",
    @[textParam(communityId), textParam(sourceId)])
  if row.isSome: parseInt(row.get.get("total")) else: 0

proc gamesPlayed(playerId: string): int =
  let row = database.queryOne(
    """select coalesce(games_played, 0)::int as total from rating.player_state
       where community_id = $1::uuid and player_id = $2::uuid""",
    @[textParam(communityId), textParam(playerId)])
  if row.isSome: parseInt(row.get.get("total")) else: 0

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
  discard database.execUpdate(
    """insert into session.game_sets
         (community_id, session_id, round_no, court_no, set_no, score_a, score_b)
       values ($1::uuid, $2::uuid, 0, 0, 1, 21, 15)""",
    @[textParam(communityId), textParam(id)])
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
    check pointEntriesFor(tournamentId) == 4
    let second = ingestTournament(database, communityId, tournamentId, params())
    check second.events == 0
    check pointEntriesFor(tournamentId) == 4

  test "a source that is not signed off is refused":
    let tournamentId = newTournament("classic", "draft")
    let pairA = newPair(tournamentId, "A", players[0], players[1])
    let pairB = newPair(tournamentId, "B", players[2], players[3])
    addMatch(tournamentId, pairA, pairB, "group-A-0", "group", 30, 20)
    let outcome = ingestTournament(database, communityId, tournamentId,
      params())
    check outcome.status == tisNotFinal
    check pointEntriesFor(tournamentId) == 0
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
    # Only the four players in this partai are counted, not the whole roster.
    check pointEntriesFor(tournamentId) == 4

  test "a tournament with several matches keeps every pair":
    let tournamentId = newTournament("classic", "completed", "2026-11-04")
    let first = newPair(tournamentId, "01", players[0], players[1])
    let second = newPair(tournamentId, "23", players[2], players[3])
    let third = newPair(tournamentId, "45", players[4], players[5])
    addMatch(tournamentId, first, second, "group-A-0", "group", 30, 20)
    addMatch(tournamentId, first, third, "group-A-1", "group", 30, 25)
    addMatch(tournamentId, second, third, "group-A-2", "group", 21, 30)
    check setFinalized(database, communityId, tournamentId, true).isSome
    check ingestTournament(database, communityId, tournamentId,
      params()).deltas == 12
    # Every pair is read once and reused, so all six players are counted in
    # both of their games.
    check pointEntriesFor(tournamentId) == 12

  test "every partai of every team match finds its own class":
    let tournamentId = newTournament("team", "completed", "2026-11-04")
    check setFinalized(database, communityId, tournamentId, true).isSome
    let teamA = newTeam(tournamentId, "RED RAPTORS", 1)
    let teamB = newTeam(tournamentId, "WHITE FURY", 2)
    addTeamPlayer(teamA, players[0], "A0", "C+")
    addTeamPlayer(teamA, players[1], "A1", "A+")
    addTeamPlayer(teamB, players[2], "B0", "C+")
    addTeamPlayer(teamB, players[3], "B1", "A+")
    for matchIndex in 0 .. 1:
      let matchId = database.queryOne(
        """insert into tournament.team_matches
             (community_id, tournament_id, phase, match_order, match_key,
              team_a_id, team_b_id)
           values ($1::uuid, $2::uuid, 'group', $3::int, $4, $5::uuid, $6::uuid)
           returning id""",
        @[textParam(communityId), textParam(tournamentId),
          intParam(matchIndex.int64), textParam("g-" & $matchIndex),
          textParam(teamA), textParam(teamB)]).get.get("id")
      for partaiIndex in 0 .. 1:
        discard database.execUpdate(
          """insert into tournament.team_partai
               (community_id, team_match_id, partai_index, score_a, score_b)
             values ($1::uuid, $2::uuid, $3::int, 30, 20)""",
          @[textParam(communityId), textParam(matchId),
            intParam(partaiIndex.int64)])
    let outcome = ingestTournament(database, communityId, tournamentId,
      params())
    check outcome.deltas == 8
    # C+ plays partai 0 and A+ partai 1, on both sides of both matches.
    check pointEntriesFor(tournamentId) == 8

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
    let sessionEntries = pointEntriesFor(sessionId)
    let tournamentEntries = pointEntriesFor(tournamentId)
    check sessionEntries > 0
    check tournamentEntries > 0

    let rebuilt = rebuild(database, communityId, params())
    # Every approved session and signed-off tournament returns; the tournament
    # event is not silently dropped by the recompute.
    check rebuilt.events == before
    check eventCount() == before
    check eventsFor(sessionId) == 1
    check eventsFor(tournamentId) == 1
    check pointEntriesFor(sessionId) == sessionEntries
    check pointEntriesFor(tournamentId) == tournamentEntries
    # Counters survive the replay too: each fresh player played one session
    # game and one tournament match.
    for player in sessionPlayers:
      check gamesPlayed(player) == 2
