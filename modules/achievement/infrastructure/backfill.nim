import std/[json, options, sets, strutils, tables, times]
import db/db
import clock
import ../domain/achievement

type
  BackfillResult* = object
    ## `players` is how many rosters were inspected; `awarded` counts rows the
    ## run actually inserted, so a second identical run reports zero.
    players*: int
    awarded*: int

  EarnRow = object
    playerId: string
    key: string

  Attendance = object
    sessions: int
    streak: int
    run: int

  GameTally = object
    games: int
    wins: int
    partners: HashSet[string]
    opponents: HashSet[string]

const playedSessions = "('locked', 'published', 'completed', 'archived')"

proc loadAttendance(conn: DbConn, communityId: string): Table[string, Attendance] =
  ## Chronological participants: an attended session extends the current run,
  ## an absence breaks it, and the stored streak is the best run so far.
  for row in conn.query(
    """select p.player_id as player_id, p.is_absent as is_absent
       from session.participants p
       join session.sessions s
         on s.community_id = p.community_id and s.id = p.session_id
       where p.community_id = $1::uuid
         and s.community_id = $1::uuid
         and s.status in """ & playedSessions & """
       order by p.player_id, s.session_date, s.id""",
    @[textParam(communityId)]):
    let playerId = row.get("player_id")
    var tally = result.mgetOrPut(playerId, Attendance())
    if row.get("is_absent") == "t":
      tally.run = 0
    else:
      inc tally.sessions
      inc tally.run
      tally.streak = max(tally.streak, tally.run)
    result[playerId] = tally

proc loadAbsent(conn: DbConn, communityId: string): HashSet[string] =
  ## A player marked absent still occupies a schedule slot, but the game did
  ## not happen for them, so it must not feed the volume or social ladders.
  for row in conn.query(
    """select p.session_id::text as session_id, p.player_id::text as player_id
       from session.participants p
       where p.community_id = $1::uuid and p.is_absent""",
    @[textParam(communityId)]):
    result.incl(row.get("session_id") & "|" & row.get("player_id"))

proc sidePlayers(row: Row, side, sessionId: string,
                 absent: HashSet[string]): seq[string] =
  for slot in ["1", "2"]:
    let playerId = row.get(side & slot)
    if playerId.len > 0 and (sessionId & "|" & playerId) notin absent:
      result.add(playerId)

proc tallySide(result: var Table[string, GameTally], side, other: seq[string],
               won: bool) =
  for playerId in side:
    var entry = result.mgetOrPut(playerId, GameTally())
    inc entry.games
    if won:
      inc entry.wins
    for mate in side:
      if mate != playerId:
        entry.partners.incl(mate)
    for opponent in other:
      entry.opponents.incl(opponent)
    result[playerId] = entry

proc loadGames(conn: DbConn, communityId: string): Table[string, GameTally] =
  ## Played games of approved sessions. Each side is tallied separately so wins
  ## and the distinct partner/opponent sets come from one pass.
  let absent = loadAbsent(conn, communityId)
  for row in conn.query(
    """select g.session_id::text as session_id,
              g.score_a as score_a, g.score_b as score_b,
              coalesce(g.side_a1::text, '') as a1,
              coalesce(g.side_a2::text, '') as a2,
              coalesce(g.side_b1::text, '') as b1,
              coalesce(g.side_b2::text, '') as b2
       from session.games g
       join session.sessions s
         on s.community_id = g.community_id and s.id = g.session_id
       where g.community_id = $1::uuid and g.status = 'played'
         and g.score_a is not null and g.score_b is not null
         and s.status in """ & playedSessions,
    @[textParam(communityId)]):
    let sessionId = row.get("session_id")
    let aSide = sidePlayers(row, "a", sessionId, absent)
    let bSide = sidePlayers(row, "b", sessionId, absent)
    let aWon = parseInt(row.get("score_a")) > parseInt(row.get("score_b"))
    result.tallySide(aSide, bSide, aWon)
    result.tallySide(bSide, aSide, not aWon)

proc loadTournaments(conn: DbConn, communityId: string): Table[string, int] =
  for row in conn.query(
    """select entry.player_id as player_id,
              count(distinct entry.tournament_id)::int as played
       from (
         select player_a_id as player_id, tournament_id
         from tournament.pairs where community_id = $1::uuid
         union all
         select player_b_id as player_id, tournament_id
         from tournament.pairs where community_id = $1::uuid
       ) entry
       group by entry.player_id""",
    @[textParam(communityId)]):
    result[row.get("player_id")] = parseInt(row.get("played"))

proc loadTiers(conn: DbConn, communityId: string): Table[string, int] =
  for row in conn.query(
    """select id, coalesce(tier, '') as tier from player.players
       where community_id = $1::uuid""",
    @[textParam(communityId)]):
    result[row.get("id")] = tierLevel(row.get("tier"))

proc loadRanks(conn: DbConn, communityId: string): Table[string, int] =
  ## Current standing on the points board; only players with evidence are
  ## ranked, so a newcomer has no rank badge.
  for row in conn.query(
    """select player_id,
              (rank() over (order by rating desc, player_id))::int as position
       from rating.player_state
       where community_id = $1::uuid and games_played > 0""",
    @[textParam(communityId)]):
    result[row.get("player_id")] = parseInt(row.get("position"))

proc loadFacts(conn: DbConn, communityId: string): seq[Facts] =
  ## The roster drives the loop, so a player with no sessions still appears
  ## (and earns nothing).
  let attendance = loadAttendance(conn, communityId)
  let games = loadGames(conn, communityId)
  let tournaments = loadTournaments(conn, communityId)
  let tiers = loadTiers(conn, communityId)
  let ranks = loadRanks(conn, communityId)
  for playerId, level in tiers:
    let attended = attendance.getOrDefault(playerId)
    let tally = games.getOrDefault(playerId)
    result.add(Facts(
      playerId: playerId,
      sessions: attended.sessions,
      streak: attended.streak,
      games: tally.games,
      wins: tally.wins,
      opponents: tally.opponents.len,
      partners: tally.partners.len,
      tournaments: tournaments.getOrDefault(playerId),
      tierLevel: level,
      rank: ranks.getOrDefault(playerId)))

proc writeAwards(conn: DbConn, communityId, earnedAt: string,
                 rows: seq[EarnRow]): int =
  ## Chunked multi-row insert. `on conflict do nothing` is what keeps
  ## `earned_at` at the date the badge was first earned.
  const chunk = 200
  var start = 0
  while start < rows.len:
    let last = min(start + chunk, rows.len)
    var params = @[textParam(communityId), timestampParam(earnedAt)]
    var values: seq[string] = @[]
    for index in start ..< last:
      let base = params.len + 1
      values.add("($1::uuid, $" & $base & "::uuid, $" & $(base + 1) & ", $2)")
      params.add(textParam(rows[index].playerId))
      params.add(textParam(rows[index].key))
    result += conn.execUpdate(
      """insert into achievement.earned
           (community_id, player_id, achievement_key, earned_at)
         values """ & values.join(", ") & """
         on conflict (community_id, player_id, achievement_key) do nothing""",
      params)
    start = last

proc backfill*(db: Db, communityId: string): BackfillResult =
  ## Awards every threshold the current data qualifies for. Idempotent: a badge
  ## that already exists keeps its original `earned_at`, and only the players
  ## whose facts crossed a new threshold gain rows.
  var outcome: BackfillResult
  discard db.tx(proc(conn: DbConn): int =
    let facts = loadFacts(conn, communityId)
    let earnedAt = utcNow().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    var rows: seq[EarnRow] = @[]
    for item in facts:
      for key in awardedKeys(item):
        rows.add(EarnRow(playerId: item.playerId, key: key))
    outcome.players = facts.len
    outcome.awarded = writeAwards(conn, communityId, earnedAt, rows)
    1)
  outcome

proc suffixThreshold(key: string): int =
  try:
    parseInt(keySuffix(key))
  except ValueError:
    0

proc listForPlayer*(db: Db, communityId, playerId: string): seq[JsonNode] =
  ## Newest first; the key breaks ties so the order is stable within a run.
  ## Catalog keys read their ladder from `achievement.definitions`; imported v1
  ## event medals (`tournament:<id>`) and the rank-streak badge have no
  ## definition row, so they fall back to the key and the stored meta.
  var ladders = initTable[string, seq[int]]()
  for row in db.query(
    """select key, threshold from achievement.definitions order by key"""):
    ladders.mgetOrPut(keyMetric(row.get("key")), @[]).add(
      parseInt(row.get("threshold")))
  for row in db.query(
    """select e.achievement_key as key, d.category as category,
              d.threshold as threshold, e.earned_at::text as earned_at,
              e.meta::text as meta
       from achievement.earned e
       left join achievement.definitions d on d.key = e.achievement_key
       where e.community_id = $1::uuid and e.player_id = $2::uuid
       order by e.earned_at desc, e.achievement_key asc""",
    @[textParam(communityId), textParam(playerId)]):
    let key = row.get("key")
    let metric = keyMetric(key)
    let category =
      if row["category"].isSome: row.get("category")
      elif metric == "tournament": "tournament"
      elif metric == "rank_streak": "rank"
      else: metric
    let threshold =
      if row["threshold"].isSome: parseInt(row.get("threshold"))
      else: suffixThreshold(key)
    let ladder =
      if metric == "tier": @[threshold]
      else: ladderFor(metric, ladders.getOrDefault(metric))
    let level = ladderLevel(metric, threshold, ladder)
    let target = nextTarget(metric, threshold, ladder)
    let nextNode = if target.isSome: %target.get else: newJNull()
    var meta =
      if row["meta"].isSome and row.get("meta").len > 0:
        parseJson(row.get("meta"))
      else:
        newJObject()
    if meta.kind != JObject:
      meta = newJObject()
    meta["metric"] = %metric
    if metric == "tier":
      meta["tier"] = %keySuffix(key)
    let title =
      if metric == "tournament" and meta.hasKey("name"):
        meta["name"].getStr()
      else:
        achievementTitle(key, category, threshold)
    let detail =
      if metric == "tournament": "Tournament medal"
      else: achievementDetail(key, category, threshold)
    result.add(%*{
      "key": key,
      "category": category,
      "threshold": threshold,
      "earnedAt": row.get("earned_at"),
      "kind": category,
      "title": title,
      "detail": detail,
      "note": "",
      "value": threshold,
      "tierLevel": if level > 0: %level else: newJNull(),
      "tierName": if level > 0: %medalTierNames[level - 1] else: newJNull(),
      "nextTarget": nextNode,
      "thresholds": %ladder,
      "meta": meta,
    })
