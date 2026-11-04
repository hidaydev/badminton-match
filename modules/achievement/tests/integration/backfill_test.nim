import std/[json, options, os, sets, strutils, unittest]
import db/db
import ../../domain/achievement
import ../../infrastructure/backfill

type
  Game = object
    ## An empty slot is a NULL on purpose: singles uses one player per side.
    a: array[2, string]
    b: array[2, string]
    scoreA: int
    scoreB: int

var
  database: Db
  communityId: string
  players: array[12, string]

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc cleanup() =
  for statement in [
    """delete from achievement.earned where community_id in
         (select id from platform.community where slug = 'achievement-club')""",
    """delete from tournament.matches where community_id in
         (select id from platform.community where slug = 'achievement-club')""",
    """delete from tournament.pairs where community_id in
         (select id from platform.community where slug = 'achievement-club')""",
    """delete from tournament.tournaments where community_id in
         (select id from platform.community where slug = 'achievement-club')""",
    """delete from session.games where community_id in
         (select id from platform.community where slug = 'achievement-club')""",
    """delete from session.participants where community_id in
         (select id from platform.community where slug = 'achievement-club')""",
    """delete from session.sessions where community_id in
         (select id from platform.community where slug = 'achievement-club')""",
    """delete from rating.deltas where community_id in
         (select id from platform.community where slug = 'achievement-club')""",
    """delete from rating.events where community_id in
         (select id from platform.community where slug = 'achievement-club')""",
    """delete from rating.player_state where community_id in
         (select id from platform.community where slug = 'achievement-club')""",
    """delete from player.players where community_id in
         (select id from platform.community where slug = 'achievement-club')""",
    "delete from platform.community where slug = 'achievement-club'"]:
    discard database.execUpdate(statement)

proc newPlayer(index: int, tier: string): string =
  database.queryOne(
    """insert into player.players (community_id, canonical_name, gender, tier)
       values ($1::uuid, $2, 'M', nullif($3, ''))
       returning id""",
    @[textParam(communityId), textParam("Achiever " & $index),
      textParam(tier)]).get.get("id")

proc seedState(player: string, rating, wins, losses: int) =
  discard database.execUpdate(
    """insert into rating.player_state
         (community_id, player_id, rating, games_played, wins, losses)
       values ($1::uuid, $2::uuid, $3, $4, $5, $6)""",
    @[textParam(communityId), textParam(player), intParam(rating.int64),
      intParam((wins + losses).int64), intParam(wins.int64),
      intParam(losses.int64)])

proc addGame(sessionId: string, roundNo: int, game: Game) =
  discard database.execUpdate(
    """insert into session.games
         (community_id, session_id, round_no, court_no, score_a, score_b,
          status, side_a1, side_a2, side_b1, side_b2)
       values ($1::uuid, $2::uuid, $3, $3, $4, $5, 'played',
               nullif($6, '')::uuid, nullif($7, '')::uuid,
               nullif($8, '')::uuid, nullif($9, '')::uuid)""",
    @[textParam(communityId), textParam(sessionId), intParam(roundNo.int64),
      intParam(game.scoreA.int64), intParam(game.scoreB.int64),
      textParam(game.a[0]), textParam(game.a[1]), textParam(game.b[0]),
      textParam(game.b[1])])

proc seedSession(date: string, games: seq[Game]): string =
  let sessionId = database.queryOne(
    """insert into session.sessions
         (community_id, title, session_date, status, source, version,
          approved_at)
       values ($1::uuid, 'Achievement night', $2::date, 'locked', 'manual', 1,
               now())
       returning id""",
    @[textParam(communityId), textParam(date)]).get.get("id")
  var roster = initHashSet[string]()
  for game in games:
    for player in [game.a[0], game.a[1], game.b[0], game.b[1]]:
      if player.len > 0:
        roster.incl(player)
  for player in roster:
    discard database.execUpdate(
      """insert into session.participants (community_id, session_id, player_id)
         values ($1::uuid, $2::uuid, $3::uuid)""",
      @[textParam(communityId), textParam(sessionId), textParam(player)])
  for roundNo, game in games:
    addGame(sessionId, roundNo, game)
  sessionId

proc seedTournament(name, playerA, playerB: string) =
  let tournamentId = database.queryOne(
    """insert into tournament.tournaments (community_id, name)
       values ($1::uuid, $2) returning id""",
    @[textParam(communityId), textParam(name)]).get.get("id")
  discard database.execUpdate(
    """insert into tournament.pairs
         (community_id, tournament_id, display_name, player_a_id, player_b_id)
       values ($1::uuid, $2::uuid, 'Pair', $3::uuid, $4::uuid)""",
    @[textParam(communityId), textParam(tournamentId), textParam(playerA),
      textParam(playerB)])

proc allRows(): seq[string] =
  ## Ordered snapshot; the checksum of the shelf has to survive a re-run.
  for row in database.query(
    """select player_id::text as player_id,
              achievement_key as key, earned_at::text as earned_at
       from achievement.earned
       where community_id = $1::uuid
       order by player_id, achievement_key""",
    @[textParam(communityId)]):
    result.add(row.get("player_id") & "|" & row.get("key") & "|" &
      row.get("earned_at"))

proc rowCount(): int =
  parseInt(database.queryOne(
    """select count(*)::int as n from achievement.earned
       where community_id = $1::uuid""", @[textParam(communityId)]).get.get("n"))

proc keysOf(playerId: string): HashSet[string] =
  for row in database.query(
    """select achievement_key as key from achievement.earned
       where community_id = $1::uuid and player_id = $2::uuid""",
    @[textParam(communityId), textParam(playerId)]):
    result.incl(row.get("key"))

proc categoriesOf(playerId: string): HashSet[string] =
  for row in database.query(
    """select distinct d.category as category
       from achievement.earned e
       join achievement.definitions d on d.key = e.achievement_key
       where e.community_id = $1::uuid and e.player_id = $2::uuid""",
    @[textParam(communityId), textParam(playerId)]):
    result.incl(row.get("category"))

proc setup() =
  database = openDb(dsn(), 1)
  cleanup()
  communityId = database.queryOne(
    """insert into platform.community (slug, name, timezone)
       values ('achievement-club', 'Achievement Club', 'Asia/Jakarta')
       returning id""").get.get("id")
  for index in 0 ..< 12:
    players[index] = newPlayer(index, if index == 0: "C" else: "")
  # Player 0 sits on top of the board; everyone else only needs a rank.
  for index in 0 ..< 12:
    let rating = if index == 0: 2000 else: 100 * (12 - index)
    seedState(players[index], rating, wins = 1, losses = 1)

proc seedFirstPhase() =
  ## 9 games for player 0: five sessions, the first one singles. Wins 9,
  ## ten distinct opponents and nine partners, so only the games ladder is
  ## still one short of its first step.
  discard seedSession("2026-11-01", @[
    Game(a: [players[0], players[1]], b: [players[6], players[7]],
      scoreA: 21, scoreB: 15)])
  for index in 1 .. 4:
    discard seedSession("2026-11-0" & $(index + 1), @[
      Game(a: [players[0], players[index + 1]],
        b: [players[index + 6], players[index + 7]], scoreA: 21, scoreB: 15),
      Game(a: [players[0], players[index + 6]],
        b: [players[index + 1], players[index + 7]], scoreA: 21, scoreB: 18)])

setup()
seedFirstPhase()
seedTournament("Autumn Open", players[0], players[1])

suite "achievement backfill":
  test "the seed carries every catalog row":
    for badge in catalog():
      let row = database.queryOne(
        """select category, threshold from achievement.definitions
           where key = $1""", @[textParam(badge.key)])
      check row.isSome
      if row.isSome:
        check row.get.get("category") == $badge.category
        check parseInt(row.get.get("threshold")) == badge.threshold

  test "the fixture earns at least one badge per seeded category":
    let result = backfill(database, communityId)
    check result.players == 12
    check result.awarded > 0
    var seeded = initHashSet[string]()
    for badge in catalog():
      seeded.incl($badge.category)
    check categoriesOf(players[0]) == seeded

  test "every threshold the data crosses is awarded":
    let keys = keysOf(players[0])
    for key in ["sessions:5", "streak:3", "streak:5", "wins:5",
                "opponents:10", "partners:5", "tournaments:1", "tier:C",
                "rank:10", "rank:5", "rank:3", "rank:2", "rank:1"]:
      check key in keys
    check "games:10" notin keys
    check "sessions:10" notin keys

  test "a second run changes nothing":
    let before = allRows()
    let result = backfill(database, communityId)
    check result.awarded == 0
    check allRows() == before

  test "a new session adds only the badges it unlocks":
    let before = allRows()
    let beforeKeys = keysOf(players[0])
    discard seedSession("2026-11-06", @[
      Game(a: [players[0], players[2]], b: [players[3], players[4]],
        scoreA: 21, scoreB: 12)])
    let result = backfill(database, communityId)
    check result.awarded == 1
    check allRows().len == before.len + 1
    let added = keysOf(players[0]) - beforeKeys
    check added == toHashSet(["games:10"])

  test "the shelf reads newest first":
    let shelf = listForPlayer(database, communityId, players[0])
    check shelf.len == keysOf(players[0]).len
    check shelf[0]["key"].getStr() == "games:10"
    for entry in shelf:
      check entry.hasKey("category")
      check entry.hasKey("threshold")
      check entry.hasKey("earnedAt")

  test "a player with no badges gets an empty array":
    let stranger = "00000000-0000-0000-0000-000000000000"
    check listForPlayer(database, communityId, stranger).len == 0

  test "an absent player earns nothing from games":
    ## The slots still name them, but the game did not happen for them.
    let sideA = [newPlayer(12, ""), newPlayer(13, "")]
    let sideB = [newPlayer(14, ""), newPlayer(15, "")]
    for day in 1 .. 10:
      let sessionId = seedSession("2026-12-" & align($day, 2, '0'), @[
        Game(a: sideA, b: sideB, scoreA: 21, scoreB: 10)])
      discard database.execUpdate(
        """update session.participants set is_absent = true
           where community_id = $1::uuid and session_id = $2::uuid""",
        @[textParam(communityId), textParam(sessionId)])
    check backfill(database, communityId).awarded == 0
    for player in [sideA[0], sideA[1], sideB[0], sideB[1]]:
      check keysOf(player).len == 0
