## Regression suite for the format rule in `docs/handbook/scoring-presets.md`
## §11.J and §13.1: one BO3 match is one game and one win, however many sets it
## contains. The existing backfill suite seeds single-set games only, so nothing
## pinned that rule; these tests read the shelf the API serves, not internals.

import std/[json, options, os, sets, strutils, unittest]
import db/db
import ../../infrastructure/backfill
import rating/domain/rating

const asOf = "2026-12-31"
const club = "achievement-format-club"

var
  database: Db
  communityId: string
  hero: string
  mates: seq[string]
  rivals: seq[string]

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

proc cleanup() =
  for statement in [
    """delete from achievement.earned where community_id in
         (select id from platform.community where slug = '""" & club & """')""",
    """delete from session.game_sets where community_id in
         (select id from platform.community where slug = '""" & club & """')""",
    """delete from session.games where community_id in
         (select id from platform.community where slug = '""" & club & """')""",
    """delete from session.participants where community_id in
         (select id from platform.community where slug = '""" & club & """')""",
    """delete from session.sessions where community_id in
         (select id from platform.community where slug = '""" & club & """')""",
    """delete from rating.events where community_id in
         (select id from platform.community where slug = '""" & club & """')""",
    """delete from rating.player_state where community_id in
         (select id from platform.community where slug = '""" & club & """')""",
    """delete from player.players where community_id in
         (select id from platform.community where slug = '""" & club & """')""",
    "delete from platform.community where slug = '" & club & "'"]:
    discard database.execUpdate(statement)

proc newPlayer(name: string): string =
  database.queryOne(
    """insert into player.players (community_id, canonical_name, gender, tier)
       values ($1::uuid, $2, 'M', null)
       returning id""",
    @[textParam(communityId), textParam(name)]).get.get("id")

proc seedBo3(date: string, sideA, sideB: seq[string],
             sets: seq[(int, int)]): string =
  ## One match, three sets at most. `session.games` holds the match and
  ## `session.game_sets` holds the sets; `session.game_results` is what turns
  ## the two into one row with a winner.
  var pointsA = 0
  var pointsB = 0
  for pair in sets:
    pointsA += pair[0]
    pointsB += pair[1]
  let sessionId = database.queryOne(
    """insert into session.sessions
         (community_id, title, session_date, status, source, version,
          approved_at, scoring_preset, scoring_rules)
       values ($1::uuid, 'BO3 night', $2::date, 'locked', 'manual', 1, now(),
               'classic21',
               '{"id":"classic21","label":"Classic BO3 21","mode":"sets",
                 "gamesToWin":2,"pointsToWin":21,"winBy":2,"deuceAt":20,
                 "maxPoints":30,"changeEndsAt":11}'::jsonb)
       returning id""",
    @[textParam(communityId), textParam(date)]).get.get("id")
  for player in sideA & sideB:
    discard database.execUpdate(
      """insert into session.participants (community_id, session_id, player_id)
         values ($1::uuid, $2::uuid, $3::uuid)""",
      @[textParam(communityId), textParam(sessionId), textParam(player)])
  database.tx(proc(conn: DbConn) =
    discard conn.execUpdate(
      """insert into session.games
           (community_id, session_id, round_no, court_no, score_a, score_b,
            status, side_a1, side_a2, side_b1, side_b2)
         values ($1::uuid, $2::uuid, 0, 0, $3, $4, 'played',
                 nullif($5, '')::uuid, nullif($6, '')::uuid,
                 nullif($7, '')::uuid, nullif($8, '')::uuid)""",
      @[textParam(communityId), textParam(sessionId),
        intParam(pointsA.int64), intParam(pointsB.int64),
        textParam(sideA[0]), textParam(if sideA.len > 1: sideA[1] else: ""),
        textParam(sideB[0]), textParam(if sideB.len > 1: sideB[1] else: "")])
    for index, pair in sets:
      discard conn.execUpdate(
        """insert into session.game_sets
             (community_id, session_id, round_no, court_no, set_no,
              score_a, score_b)
           values ($1::uuid, $2::uuid, 0, 0, $3, $4, $5)""",
        @[textParam(communityId), textParam(sessionId),
          intParam((index + 1).int64), intParam(pair[0].int64),
          intParam(pair[1].int64)]))
  # The ticker writes one event per approved session, and the board reads them.
  discard database.execUpdate(
    """insert into rating.events (community_id, local_date, event_type, source_id)
       values ($1::uuid, $2::date, 'session', $3::uuid)""",
    @[textParam(communityId), textParam(date), textParam(sessionId)])
  sessionId

proc keysOf(playerId: string): HashSet[string] =
  for row in database.query(
    """select achievement_key as key from achievement.earned
       where community_id = $1::uuid and player_id = $2::uuid""",
    @[textParam(communityId), textParam(playerId)]):
    result.incl(row.get("key"))

proc shelfEntry(playerId, key: string): JsonNode =
  for entry in listForPlayer(database, communityId, playerId, 200, 0):
    if entry["key"].getStr() == key:
      return entry
  newJNull()

proc setup() =
  database = openDb(dsn(), 1)
  cleanup()
  communityId = database.queryOne(
    """insert into platform.community (slug, name, timezone)
       values ($1, 'Achievement Format Club', 'Asia/Jakarta')
       returning id""", @[textParam(club)]).get.get("id")
  hero = newPlayer("Hero")
  for index in 1 .. 5:
    mates.add(newPlayer("Mate " & $index))
  for index in 1 .. 5:
    rivals.add(newPlayer("Rival " & $index))

proc seedTenBo3() =
  ## Ten matches for the hero: five 2-0 and five 2-1. If a set counted as a
  ## game the shelf would claim 25 games and 25 wins.
  for index in 0 ..< 10:
    let date = "2026-11-" & align($(index + 1), 2, '0')
    let sideA = @[hero, mates[index mod 5]]
    let sideB = @[rivals[index mod 5], rivals[(index + 1) mod 5]]
    let sets =
      if index mod 2 == 0: @[(21, 15), (21, 18)]
      else: @[(19, 21), (21, 18), (21, 19)]
    discard seedBo3(date, sideA, sideB, sets)

setup()
seedTenBo3()
discard backfill(database, communityId, asOf, params())

suite "achievement format rule (§11.J, §13.1)":
  test "ten BO3 matches are ten games, not twenty-five":
    let keys = keysOf(hero)
    check "games:10" in keys
    check "games:25" notin keys

  test "a 2-0 win and a 2-1 win both count as one win":
    ## Five sets won per 2-1 match would put the hero at 25 wins and earn
    ## `wins:20`; the ladder must stop at the ten matches actually won.
    let keys = keysOf(hero)
    check "wins:5" in keys
    check "wins:20" notin keys

  test "ten sessions are ten sessions whatever the format":
    let keys = keysOf(hero)
    check "sessions:5" in keys
    check "sessions:10" in keys
    check "sessions:15" notin keys

  test "the shelf reports the rung the match count reached":
    let games = shelfEntry(hero, "games:10")
    check games.kind == JObject
    check games["value"].getInt() == 10
    check games["thresholds"].len == 5
    check games["tierLevel"].getInt() == 1
    check games["tierName"].getStr() == "Bronze"
    check games["nextTarget"].getInt() == 25
    check games["title"].getStr() == "Games 10"
    check games["detail"].getStr() == "Play 10 games."
