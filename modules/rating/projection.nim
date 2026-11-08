## The public board, computed the way v1 computed it.
##
## v1 kept one rating event per played game and re-derived the points on every
## read; nothing was stored. v2 keeps an integer ledger for game counts, but the
## board is rebuilt from the games so a stored delta never rounds a total.
##
## The rules are v1's (`store/rank_points.go`):
##   * one source is one entry: a session's entry is the sum of its games, a
##     tournament's entry is `champion_points * round_ratio(placement)`,
##   * a game is worth `base * (0.5 + 0.5 * clamp(margin/target, -1, 1))`,
##   * the opponent multiplier is the opponents' sticky tier strength over the
##     population's, clamped; a tier does not drift with results,
##   * the board keeps the best `best_n` entries inside the rolling window.
##
## A tournament format without an enabled level row falls back to the game
## formula, exactly like v1.

import std/[algorithm, json, math, options, sets, strutils, tables]
import db/db
import ./domain/rating
import ./infrastructure/tournament
import session/lifecycle
import session/scoring as sessionScoring
import session/sides

type
  Entry* = object
    ## One sourced result for one player.
    sourceId*: string
    date*: string
    kind*: string
    points*: float
    games*: int
    result*: string

  Projection* = object
    ## A player's window: every entry, the best `counted` of them, and the
    ## rounded total the board shows.
    entries*: seq[Entry]
    counted*: int
    available*: int
    points*: int
    thinEvidence*: bool

  Level* = object
    ## Exported with its fields for `projection_rules_test` (D-5): a tournament
    ## level carries the champion points and the per-placement ratios.
    champion*: float
    ratios*: JsonNode
    enabled*: bool

  Place* = object
    ## How far a player got in one tournament. The placement key is derived
    ## from these three facts, never stored per game. Exported with its fields
    ## for `projection_rules_test` (D-5), which is the only direct caller of the
    ## rules below.
    bestRank*: int
    anyWin*: bool
    finalOutcome*: string

  Acc = object
    date: string
    kind: string
    points: float
    games: int
    place: Place
    usesLevel: bool

const keySeparator = "\x00"

proc defaultRatio*(key: string): float =
  ## v1's §4.4 fallback for a ratio the ladder row does not carry. Exported for
  ## `projection_rules_test` (D-5) so the fallback table has a direct case.
  case key
  of "final": 1.0
  of "runner_up": 0.85
  of "sf": 0.7
  of "qf": 0.55
  of "group": 0.4
  of "participant": 0.2
  else: 0.0

proc ratioOf*(level: Level, key: string): float =
  ## The ladder row first, `defaultRatio` otherwise. Exported for
  ## `projection_rules_test` (D-5); the level is not loaded here.
  if level.ratios.kind == JObject and level.ratios.hasKey(key):
    return level.ratios[key].getFloat()
  defaultRatio(key)

proc phaseRank*(phase: string): int =
  ## Farther in the bracket ranks higher; the third-place match is a semifinal
  ## loser's game, so it counts as a semifinal. Exported for
  ## `projection_rules_test` (D-5): the ordering is a v1 rule, not an artifact
  ## of the batch query.
  case phase
  of "final": 4
  of "sf", "3rd": 3
  of "qf": 2
  of "group": 1
  else: 0

proc resultKey*(place: Place): string =
  ## v1's rule: a champion is `final`, a finalist who won earlier is
  ## `runner_up`, no win at all is `participant`, anything else is the phase
  ## the player reached. Exported for `projection_rules_test` (D-5).
  if not place.anyWin:
    return "participant"
  if place.bestRank >= 4:
    return if place.finalOutcome == "W": "final" else: "runner_up"
  case place.bestRank
  of 3: "sf"
  of 2: "qf"
  of 1: "group"
  else: "participant"

proc splitKey*(key: string): (string, string) =
  ## Splits the accumulator key back into owner and source. Exported for
  ## `projection_rules_test` (D-5) so the separator round-trip has a case.
  let index = key.find(keySeparator)
  if index < 0: (key, "") else: (key[0 ..< index], key[index + 1 .. ^1])

proc loadTiers(db: Db, communityId: string): Table[string, string] =
  for row in db.query(
    """select id::text as id, coalesce(tier, '') as tier
       from player.players where community_id = $1::uuid""",
    @[textParam(communityId)]):
    result[row.getUuid("id")] = row.get("tier")

proc populationStrength(tiers: Table[string, string],
                        params: RatingParams): float =
  ## The neutral point of the multiplier: every player with a known tier, not
  ## just the ones on the board.
  var total = 0.0
  var seen = 0
  for tier in tiers.values:
    let value = tierStrength(params, tier)
    if value.isSome:
      total += value.get
      inc seen
  if seen == 0: 0.0 else: total / seen.float

proc opponentsStrength(tiers: Table[string, string], params: RatingParams,
                       ids: seq[string]): float =
  var total = 0.0
  var seen = 0
  for id in ids:
    let value = tierStrength(params, tiers.getOrDefault(id))
    if value.isSome:
      total += value.get
      inc seen
  if seen == 0: 0.0 else: total / seen.float

proc loadLevels(db: Db, communityId: string): Table[string, Level] =
  for row in db.query(
    """select kind, champion_points::text as champion,
              round_ratios::text as ratios, enabled
       from rating.levels where community_id = $1::uuid""",
    @[textParam(communityId)]):
    let raw = row.get("ratios")
    result[row.get("kind")] = Level(
      champion: parseFloat(row.get("champion")),
      ratios: if raw.len == 0: newJObject() else: parseJson(raw),
      enabled: row.getBool("enabled"))

proc addGame(acc: var Table[string, Acc], playerId, sourceId, date, kind: string,
             points: float) =
  let key = playerId & keySeparator & sourceId
  var entry = acc.getOrDefault(key)
  if entry.date.len == 0:
    entry.date = date
    entry.kind = kind
  entry.points += points
  inc entry.games
  acc[key] = entry

proc sessionEntries(db: Db, communityId, asOf: string,
                    params: RatingParams, tiers: Table[string, string],
                    population: float, acc: var Table[string, Acc]) =
  ## Sessions are one query plus the two exclusion tables, so a board read does
  ## not issue a query per session. A skipped or absent player contributes
  ## nothing, not even to the opponents' average, exactly like the ingest.
  var absentBySession = initTable[string, HashSet[string]]()
  for row in db.query(
    """select session_id::text as session_id, player_id::text as player_id
       from session.participants
       where community_id = $1::uuid and is_absent""",
    @[textParam(communityId)]):
    absentBySession.mgetOrPut(row.getUuid("session_id"),
      initHashSet[string]()).incl(row.getUuid("player_id"))
  var skipsBySession = initTable[string, Table[string, HashSet[string]]]()
  for row in db.query(
    """select session_id::text as session_id, round_no, court_no,
              player_id::text as player_id
       from session.game_skips where community_id = $1::uuid""",
    @[textParam(communityId)]):
    skipsBySession.mgetOrPut(row.getUuid("session_id"),
      initTable[string, HashSet[string]]()).mgetOrPut(
        row.get("round_no") & "-" & row.get("court_no"),
        initHashSet[string]()).incl(row.getUuid("player_id"))
  for row in db.query(
    """select e.source_id::text as source_id, e.local_date::text as local_date,
              r.round_no, r.court_no, r.points_a, r.points_b, r.sets_played,
              coalesce((s.scoring_rules->>'pointsToWin')::int, $4::int) as target,
              coalesce(r.side_a1::text, '') as a1,
              coalesce(r.side_a2::text, '') as a2,
              coalesce(r.side_b1::text, '') as b1,
              coalesce(r.side_b2::text, '') as b2
       from rating.events e
       join session.game_results r
         on r.community_id = e.community_id and r.session_id = e.source_id
       join session.sessions s
         on s.community_id = e.community_id and s.id = e.source_id
       where e.community_id = $1::uuid and e.event_type = 'session'
         and e.local_date >= $2::date - ($3::int * 7)
         and e.local_date <= $2::date
         and s.approved_at is not null
         and s.status in """ & approvedStatuses & """
         and r.status = 'played' and r.winner <> ''
       order by e.local_date, r.round_no, r.court_no""",
    @[textParam(communityId), textParam(asOf),
      intParam(params.windowWeeks.int64),
      intParam(params.scoreTarget.int64)]):
    let sourceId = row.getUuid("source_id")
    let date = row.get("local_date")
    let gameKey = row.get("round_no") & "-" & row.get("court_no")
    let pointsA = row.getInt("points_a")
    let pointsB = row.getInt("points_b")
    let setsPlayed = row.getInt("sets_played")
    let target = row.getInt("target")
    let split = sides(row.get("a1"), row.get("a2"), row.get("b1"),
      row.get("b2"), absentBySession.getOrDefault(sourceId),
      skipsBySession.getOrDefault(sourceId).getOrDefault(gameKey))
    if not split.counts:
      continue
    let multiplierA = opponentMultiplier(params,
      opponentsStrength(tiers, params, split.eligibleB), population)
    let multiplierB = opponentMultiplier(params,
      opponentsStrength(tiers, params, split.eligibleA), population)
    let ratio = sessionScoring.ratingMarginFrom(pointsA, pointsB, setsPlayed,
      target)
    let valueA = gameValue(params.sessionBase, ratio * target.float,
      target.float)
    let valueB = gameValue(params.sessionBase, -ratio * target.float,
      target.float)
    for id in split.eligibleA:
      addGame(acc, id, sourceId, date, "session", valueA * multiplierA)
    for id in split.eligibleB:
      addGame(acc, id, sourceId, date, "session", valueB * multiplierB)

proc tournamentEntries(db: Db, communityId, asOf: string,
                       params: RatingParams, tiers: Table[string, string],
                       population: float, levels: Table[string, Level],
                       acc: var Table[string, Acc]) =
  for header in db.query(
    """select e.source_id::text as id, e.local_date::text as local_date,
              t.format
       from rating.events e
       join tournament.tournaments t
         on t.community_id = e.community_id and t.id = e.source_id
       where e.community_id = $1::uuid and e.event_type = 'tournament'
         and e.local_date >= $2::date - ($3::int * 7)
         and e.local_date <= $2::date
       order by e.local_date, e.source_id""",
    @[textParam(communityId), textParam(asOf),
      intParam(params.windowWeeks.int64)]):
    let sourceId = header.getUuid("id")
    let date = header.get("local_date")
    let format = header.get("format")
    let kind = "tournament_" & format
    let level = levels.getOrDefault(kind)
    let usesLevel = levels.hasKey(kind) and level.enabled
    var places = initTable[string, Place]()
    # One short-lived connection per tournament; the header query above
    # already released its own.
    let games = db.read(proc(conn: DbConn): seq[TournamentGame] =
      gamesFor(conn, communityId, sourceId, format))
    for game in games:
      let marginA = game.scoreA - game.scoreB
      if usesLevel:
        for side in [true, false]:
          let players = if side: game.sideA else: game.sideB
          let won = if side: marginA > 0 else: marginA < 0
          for id in players:
            var place = places.getOrDefault(id)
            place.bestRank = max(place.bestRank, phaseRank(game.phase))
            place.anyWin = place.anyWin or won
            if game.phase == "final":
              place.finalOutcome = (if won: "W" else: "L")
            places[id] = place
            addGame(acc, id, sourceId, date, kind, 0.0)
        continue
      let multiplierA = opponentMultiplier(params,
        opponentsStrength(tiers, params, game.sideB), population)
      let multiplierB = opponentMultiplier(params,
        opponentsStrength(tiers, params, game.sideA), population)
      let valueA = gameValue(params.sessionBase, marginA.float,
        game.target.float)
      let valueB = gameValue(params.sessionBase, (-marginA).float,
        game.target.float)
      for id in game.sideA:
        addGame(acc, id, sourceId, date, kind, valueA * multiplierA)
      for id in game.sideB:
        addGame(acc, id, sourceId, date, kind, valueB * multiplierB)
    if not usesLevel:
      continue
    for id, place in places:
      let key = id & keySeparator & sourceId
      var entry = acc.getOrDefault(key)
      entry.points = level.champion * ratioOf(level, resultKey(place))
      entry.place = place
      entry.usesLevel = true
      acc[key] = entry

proc project*(db: Db, communityId, asOf: string, params: RatingParams,
              playerId = ""): Table[string, Projection] =
  ## Every player with at least one entry in the window, or only `playerId`
  ## when it is given. The caller decides who reaches the board.
  ##
  ## The read is deliberately not wrapped in a transaction. Each statement
  ## checks a connection out of the pool and returns it, so a board request
  ## never pins one for the whole aggregation; with a pool sized to the worker
  ## count, a handful of concurrent boards would otherwise lock capacity. The
  ## board is a point-in-time report either way: READ COMMITTED gives every
  ## statement its own snapshot, with or without the outer BEGIN.
  var grouped = initTable[string, seq[Entry]]()
  let tiers = loadTiers(db, communityId)
  let population = populationStrength(tiers, params)
  let levels = loadLevels(db, communityId)
  var acc = initTable[string, Acc]()
  sessionEntries(db, communityId, asOf, params, tiers, population, acc)
  tournamentEntries(db, communityId, asOf, params, tiers, population, levels,
    acc)
  for key, value in acc:
    let (owner, sourceId) = splitKey(key)
    if playerId.len > 0 and owner != playerId:
      continue
    grouped.mgetOrPut(owner, @[]).add(Entry(sourceId: sourceId,
      date: value.date, kind: value.kind, points: value.points,
      games: value.games,
      result: (if value.usesLevel: resultKey(value.place) else: "")))
  for owner, entries in grouped:
    var list = entries
    list.sort(proc(a, b: Entry): int =
      if a.points != b.points: cmp(b.points, a.points)
      elif a.date != b.date: cmp(b.date, a.date)
      else: cmp(a.sourceId, b.sourceId))
    let available = list.len
    let counted = min(params.bestN, available)
    var total = 0.0
    for index in 0 ..< counted:
      total += list[index].points
    result[owner] = Projection(entries: list, counted: counted,
      available: available, points: int(round(total)),
      thinEvidence: available < params.thinEvidenceN)
