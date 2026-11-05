import std/[json, options, os, sets, strutils, tables, unittest]
import db/db
import ../../domain/achievement
import ../../infrastructure/backfill
import rating/domain/rating
import rating/read

type
  Game = object
    ## An empty slot is a NULL on purpose: singles uses one player per side.
    a: array[2, string]
    b: array[2, string]
    scoreA: int
    scoreB: int

const asOf = "2026-12-31"

var
  database: Db
  communityId: string
  players: array[12, string]
  streakPlayer: string

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc params(): RatingParams =
  ## The registry values, spelled out so the test owns the board it asserts on.
  RatingParams(sessionBase: 250, scoreTarget: 21, opponentClampLow: 0.5,
    opponentClampHigh: 1.5, windowWeeks: 12, bestN: 10, thinEvidenceN: 3,
    bands: @[
      TierBand(tier: "D", floor: 1000, ceiling: some(1199.0)),
      TierBand(tier: "C", floor: 1300, ceiling: some(1499.0)),
      TierBand(tier: "B", floor: 1600, ceiling: some(1799.0)),
      TierBand(tier: "A+", floor: 2100, ceiling: none(float))])

proc award(): BackfillResult =
  backfill(database, communityId, asOf, params())

proc cleanup() =
  for statement in [
    """delete from achievement.earned where community_id in
         (select id from platform.community where slug = 'achievement-club')""",
    """delete from achievement.definitions
         where key = 'tournament:11111111-1111-1111-1111-111111111111'""",
    """delete from tournament.team_partai where community_id in
         (select id from platform.community where slug = 'achievement-club')""",
    """delete from tournament.team_matches where community_id in
         (select id from platform.community where slug = 'achievement-club')""",
    """delete from tournament.team_players where community_id in
         (select id from platform.community where slug = 'achievement-club')""",
    """delete from tournament.teams where community_id in
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

proc skipGame(sessionId: string, roundNo: int, playerId: string) =
  discard database.execUpdate(
    """insert into session.game_skips
         (community_id, session_id, round_no, court_no, player_id)
       values ($1::uuid, $2::uuid, $3, $3, $4::uuid)""",
    @[textParam(communityId), textParam(sessionId), intParam(roundNo.int64),
      textParam(playerId)])

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
  # The ticker writes one event per approved session, and the board reads them;
  # a medal rank comes from that board, not from `rating.player_state`.
  discard database.execUpdate(
    """insert into rating.events (community_id, local_date, event_type, source_id)
       values ($1::uuid, $2::date, 'session', $3::uuid)""",
    @[textParam(communityId), textParam(date), textParam(sessionId)])
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

proc seedEventDate(date: string) =
  ## An event date with no session behind it: the rank streak walks the
  ## community's distinct event dates, so the date is all the fixture needs.
  discard database.execUpdate(
    """insert into rating.events (community_id, local_date, event_type)
       values ($1::uuid, $2::date, 'manual')""",
    @[textParam(communityId), textParam(date)])

proc seedRankSnapshot(playerId, date: string, rank: int) =
  ## The streak reads only the recorded rank, never the points beside it.
  discard database.execUpdate(
    """insert into rating.snapshots
         (community_id, player_id, taken_on, rating, rank)
       values ($1::uuid, $2::uuid, $3::date, 1500, $4)""",
    @[textParam(communityId), textParam(playerId), textParam(date),
      intParam(rank.int64)])

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
  # The ledger is seeded too, because production has it; it must not decide a
  # rank badge. Player 0 still lands on top, this time from the games.
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
    let result = award()
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
    let result = award()
    check result.awarded == 0
    check allRows() == before
    # The config-resolving entry point the v1 import uses reads the same roster.
    check backfill(database, communityId).players == result.players

  test "a new session adds only the badges it unlocks":
    let before = allRows()
    let beforeKeys = keysOf(players[0])
    # Dated past the board anchor on purpose: the extra games count, while the
    # rank table the run reads stays exactly where the fixture left it.
    discard seedSession("2027-01-05", @[
      Game(a: [players[0], players[2]], b: [players[3], players[4]],
        scoreA: 21, scoreB: 12)])
    let result = award()
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

  test "the shelf carries catalog labels and the medal ladder":
    var byKey = initTable[string, JsonNode]()
    for entry in listForPlayer(database, communityId, players[0]):
      byKey[entry["key"].getStr()] = entry
    let sessions = byKey["sessions:5"]
    check sessions["kind"].getStr() == "attendance"
    check sessions["title"].getStr() == "Sessions 5"
    check sessions["detail"].getStr() == "Attend 5 sessions."
    check sessions["note"].getStr() == ""
    check sessions["value"].getInt() == 5
    check sessions["thresholds"].len == 5
    check sessions["tierLevel"].getInt() == 1
    check sessions["tierName"].getStr() == "Bronze"
    check sessions["nextTarget"].getInt() == 10
    check sessions["meta"]["metric"].getStr() == "sessions"
    # Rank improves downward: the ladder starts at #10 and ends at #1.
    let rank = byKey["rank:1"]
    check rank["thresholds"][0].getInt() == 10
    check rank["tierLevel"].getInt() == 5
    check rank["tierName"].getStr() == "Onyx"
    check rank["nextTarget"].kind == JNull
    # Tier keys encode their level in the key, so they stay off the ladder.
    let tier = byKey["tier:C"]
    check tier["title"].getStr() == "Tier C"
    check tier["tierLevel"].kind == JNull
    check tier["tierName"].kind == JNull
    check tier["nextTarget"].kind == JNull
    check tier["thresholds"].len == 1
    check tier["meta"]["tier"].getStr() == "C"

  test "a player with no badges gets an empty array":
    let stranger = "00000000-0000-0000-0000-000000000000"
    check listForPlayer(database, communityId, stranger).len == 0

  test "an imported rank-streak row carries the v1 ladder":
    discard database.execUpdate(
      """insert into achievement.earned
           (community_id, player_id, achievement_key, earned_at, meta)
         values ($1::uuid, $2::uuid, 'rank_streak:11', now(), '{}'::jsonb)
         on conflict do nothing""",
      @[textParam(communityId), textParam(players[0])])
    var found = newJObject()
    for entry in listForPlayer(database, communityId, players[0]):
      if entry["key"].getStr() == "rank_streak:11":
        found = entry
    check found["title"].getStr() == "Rank streak 11"
    check found["category"].getStr() == "rank"
    check found["value"].getInt() == 11
    check found["thresholds"].len == 5
    check found["tierLevel"].getInt() == 3
    check found["tierName"].getStr() == "Gold"
    check found["nextTarget"].getInt() == 12
    check found["meta"]["metric"].getStr() == "rank_streak"

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
    check award().awarded == 0
    for player in [sideA[0], sideA[1], sideB[0], sideB[1]]:
      check keysOf(player).len == 0

  test "a skipped game leaves no trace in the tallies":
    ## The slots still name them and they are on the roster, but they sat the
    ## game out: no game, no win, and no partner or opponent named for anyone.
    let sitter = newPlayer(16, "")
    let mate = newPlayer(17, "")
    let rivals = [newPlayer(18, ""), newPlayer(19, "")]
    for day in 1 .. 10:
      let sessionId = seedSession("2026-11-" & align($(day + 9), 2, '0'), @[
        Game(a: [sitter, mate], b: rivals, scoreA: 21, scoreB: 5)])
      skipGame(sessionId, roundNo = 0, playerId = sitter)
    discard award()
    check "games:10" notin keysOf(sitter)
    check "wins:5" notin keysOf(sitter)
    check "games:10" in keysOf(mate)

  test "a skipped opponent is not someone the other side faced":
    ## `rival` meets ten different players in five sessions; one of the ten sat
    ## a game out, so nine were actually faced and the ladder stops at #10.
    let rival = [newPlayer(20, ""), newPlayer(21, "")]
    for day in 1 .. 5:
      let pair = [newPlayer(20 + 2 * day, ""), newPlayer(21 + 2 * day, "")]
      let sessionId = seedSession("2026-11-" & align($(day + 9), 2, '0'), @[
        Game(a: pair, b: rival, scoreA: 21, scoreB: 15)])
      if day == 1:
        skipGame(sessionId, roundNo = 0, playerId = pair[0])
    discard award()
    check "opponents:10" notin keysOf(rival[0])

  test "a rank badge follows the board, not the ledger":
    ## `rating.player_state.rating` is an all-time accumulator. Here it puts one
    ## player far ahead while the best-N board puts another first, and the badge
    ## has to agree with the list the members read.
    let ledgerKing = newPlayer(32, "")
    let boardKing = newPlayer(33, "")
    seedState(ledgerKing, 99999, wins = 1, losses = 1)
    seedState(boardKing, 1, wins = 1, losses = 1)
    let extra = [newPlayer(34, ""), newPlayer(35, "")]
    for day in 1 .. 10:
      discard seedSession("2026-11-" & align($day, 2, '0'), @[
        Game(a: [boardKing, extra[0]], b: [extra[1], ledgerKing],
          scoreA: 21, scoreB: 2)])
    discard award()
    check "rank:1" in keysOf(boardKing)
    check "rank:1" notin keysOf(ledgerKing)

  test "a team roster counts the tournament":
    ## A team event names its players in `team_players`; its `pairs` table is
    ## empty, so the tournament ladder used to miss the whole event.
    let rostered = newPlayer(36, "")
    let tournamentId = database.queryOne(
      """insert into tournament.tournaments (community_id, name, format)
         values ($1::uuid, 'Team Cup', 'team') returning id""",
      @[textParam(communityId)]).get.get("id")
    let teamId = database.queryOne(
      """insert into tournament.teams
           (community_id, tournament_id, seed, team_name)
         values ($1::uuid, $2::uuid, 1, 'Red') returning id""",
      @[textParam(communityId), textParam(tournamentId)]).get.get("id")
    discard database.execUpdate(
      """insert into tournament.team_players
           (community_id, team_id, player_name, player_id, cls)
         values ($1::uuid, $2::uuid, 'Team Player', $3::uuid, 'A')""",
      @[textParam(communityId), textParam(teamId), textParam(rostered)])
    discard award()
    check "tournaments:1" in keysOf(rostered)

  test "every rank badge the board implies is on the shelf":
    ## A rank badge follows the current board: a player who slipped past a rung
    ## loses it on the next reconciliation, and the check is that the current
    ## rank never lacks its rungs.
    var ranks = initTable[string, int]()
    for row in board(database, BoardQuery(communityId: communityId, asOf: asOf,
      params: params(), limit: 0)):
      ranks[row.playerId] = row.rank
    check ranks.len > 0
    for playerId, rank in ranks:
      let keys = keysOf(playerId)
      for threshold in [10, 5, 3, 2, 1]:
        if rank <= threshold:
          check ("rank:" & $threshold) in keys

  test "a reverted session revokes the catalog badge it earned":
    ## The pass is a reconciliation, not insert-only: once the session and its
    ## rating event are gone, a catalog key the player no longer crosses goes
    ## with it. Imported rows outside the catalog stay on the shelf.
    let solo = newPlayer(40, "")
    let mate = newPlayer(41, "")
    let rivals = [newPlayer(42, ""), newPlayer(43, "")]
    var sessionIds: seq[string] = @[]
    for day in 1 .. 5:
      sessionIds.add(seedSession("2026-10-" & align($(day + 9), 2, '0'), @[
        Game(a: [solo, mate], b: rivals, scoreA: 21, scoreB: 10)]))
    discard award()
    check "sessions:5" in keysOf(solo)
    let eventKey = "tournament:11111111-1111-1111-1111-111111111111"
    discard database.execUpdate(
      """insert into achievement.definitions (key, category, threshold)
         values ($1, 'tournament', 1) on conflict (key) do nothing""",
      @[textParam(eventKey)])
    discard database.execUpdate(
      """insert into achievement.earned
           (community_id, player_id, achievement_key, earned_at, meta)
         values ($1::uuid, $2::uuid, $3, now(), '{}'::jsonb),
                ($1::uuid, $2::uuid, 'rank_streak:11', now(), '{}'::jsonb)
         on conflict do nothing""",
      @[textParam(communityId), textParam(solo), textParam(eventKey)])
    for sessionId in sessionIds:
      discard database.execUpdate(
        """delete from session.games
           where community_id = $1::uuid and session_id = $2::uuid""",
        @[textParam(communityId), textParam(sessionId)])
      discard database.execUpdate(
        """delete from session.participants
           where community_id = $1::uuid and session_id = $2::uuid""",
        @[textParam(communityId), textParam(sessionId)])
      discard database.execUpdate(
        """delete from session.sessions
           where community_id = $1::uuid and id = $2::uuid""",
        @[textParam(communityId), textParam(sessionId)])
      discard database.execUpdate(
        """delete from rating.events
           where community_id = $1::uuid and event_type = 'session'
             and source_id = $2::uuid""",
        @[textParam(communityId), textParam(sessionId)])
    let result = award()
    check result.revoked > 0
    check "sessions:5" notin keysOf(solo)
    check eventKey in keysOf(solo)
    # The imported run came from v1's own board history, which v2 cannot
    # recompute, so the badge stays even though this pass has no rank history.
    check "rank_streak:11" in keysOf(solo)
    # Leave the shared definitions table as the fixture found it.
    discard database.execUpdate(
      "delete from achievement.earned where achievement_key = $1",
      @[textParam(eventKey)])
    discard database.execUpdate(
      "delete from achievement.definitions where key = $1",
      @[textParam(eventKey)])

  test "the rank streak is the longest run of event dates at rank 3 or better":
    ## Two dates at #2, one at #4 that breaks the run, then five at #1, so the
    ## longest qualifying run is 5. The run counts event dates, not calendar
    ## days, and the badge stores that number rather than the rung below it.
    streakPlayer = newPlayer(50, "")
    let ranks = [2, 2, 4, 1, 1, 1, 1, 1]
    for index, rank in ranks:
      let day = "2025-03-" & align($(index + 1), 2, '0')
      seedEventDate(day)
      seedRankSnapshot(streakPlayer, day, rank)
    discard award()
    check "rank_streak:5" in keysOf(streakPlayer)
    check "rank_streak:3" notin keysOf(streakPlayer)
    var streakKeys = 0
    for key in keysOf(streakPlayer):
      if key.startsWith("rank_streak:"):
        inc streakKeys
    check streakKeys == 1

  test "re-awarding the rank streak changes nothing":
    let before = allRows()
    let result = award()
    check result.awarded == 0
    check allRows() == before
    check "rank_streak:5" in keysOf(streakPlayer)

  test "a recorded rank streak outlives the snapshots behind it":
    ## An earned badge is never taken back: a run that a later pass can no
    ## longer see is still a run the player had, and v2 cannot tell its own row
    ## from an imported one. The tournament medal beside it stays too.
    let eventKey = "tournament:22222222-2222-2222-2222-222222222222"
    discard database.execUpdate(
      """insert into achievement.definitions (key, category, threshold)
         values ($1, 'tournament', 1) on conflict (key) do nothing""",
      @[textParam(eventKey)])
    discard database.execUpdate(
      """insert into achievement.earned
           (community_id, player_id, achievement_key, earned_at)
         values ($1::uuid, $2::uuid, $3, now())
         on conflict do nothing""",
      @[textParam(communityId), textParam(streakPlayer), textParam(eventKey)])
    discard database.execUpdate(
      """delete from rating.snapshots
         where community_id = $1::uuid and player_id = $2::uuid""",
      @[textParam(communityId), textParam(streakPlayer)])
    discard award()
    check "rank_streak:5" in keysOf(streakPlayer)
    check eventKey in keysOf(streakPlayer)

  test "a tournament medal survives every later pass":
    let eventKey = "tournament:22222222-2222-2222-2222-222222222222"
    let before = allRows()
    let result = award()
    check result.awarded == 0
    check allRows() == before
    check eventKey in keysOf(streakPlayer)
    check "rank_streak:5" in keysOf(streakPlayer)
    # Leave the shared definitions table as the fixture found it.
    discard database.execUpdate(
      "delete from achievement.earned where achievement_key = $1",
      @[textParam(eventKey)])
    discard database.execUpdate(
      "delete from achievement.definitions where key = $1",
      @[textParam(eventKey)])
