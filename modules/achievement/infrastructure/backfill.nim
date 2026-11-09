import std/[json, options, sets, strutils, tables, times]
import db/db
import clock
import platform/config/store
import rating/domain/rating
import rating/infrastructure/params
import rating/read
import session/lifecycle
import session/sides
import tournament/domain/team
import ../domain/achievement

type
  BackfillResult* = object
    ## `players` is how many rosters were inspected; `awarded` counts rows the
    ## run actually inserted, so a second identical run reports zero; `revoked`
    ## counts stale rows the reconciliation removed, the v2-owned rank-streak
    ## family included.
    players*: int
    awarded*: int
    revoked*: int

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

  RankStreak = object
    ## `best` is the longest run counted so far; `endedOn` is the event date
    ## that closed it, so a later pass can tell the run apart from the shelf.
    best: int
    endedOn: string

## A rank-streak run counts a date where the player sat at this rank or better,
## and a run shorter than the first rung of the v1 ladder earns nothing.
const streakRankThreshold = 3
const streakMinLength = 3
const rankStreakPrefix = "rank_streak:"

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
         and s.status in """ & approvedStatuses & """
       order by p.player_id, s.session_date, s.id""",
    @[textParam(communityId)]):
    let playerId = row.getUuid("player_id")
    var tally = result.mgetOrPut(playerId, Attendance())
    if row.getBool("is_absent"):
      tally.run = 0
    else:
      inc tally.sessions
      inc tally.run
      tally.streak = max(tally.streak, tally.run)
    result[playerId] = tally

proc loadAbsent(conn: DbConn, communityId: string):
    Table[string, HashSet[string]] =
  ## A player marked absent still occupies a schedule slot, but the game did
  ## not happen for them, so it must not feed the volume or social ladders.
  for row in conn.query(
    """select p.session_id::text as session_id, p.player_id::text as player_id
       from session.participants p
       where p.community_id = $1::uuid and p.is_absent""",
    @[textParam(communityId)]):
    result.mgetOrPut(row.getUuid("session_id"),
      initHashSet[string]()).incl(row.getUuid("player_id"))

proc loadSkips(conn: DbConn, communityId: string):
    Table[string, Table[string, HashSet[string]]] =
  ## A skipped player was at the session but sat this game out, so the game is
  ## neither theirs nor a partner or opponent of anyone else in it.
  for row in conn.query(
    """select session_id::text as session_id, round_no, court_no,
              player_id::text as player_id
       from session.game_skips
       where community_id = $1::uuid""",
    @[textParam(communityId)]):
    result.mgetOrPut(row.getUuid("session_id"),
      initTable[string, HashSet[string]]()).mgetOrPut(
        row.get("round_no") & "-" & row.get("court_no"),
        initHashSet[string]()).incl(row.getUuid("player_id"))

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

proc tallyResult(result: var Table[string, GameTally], side: seq[string],
                 won: bool) =
  ## Games and wins only. The global partner/opponent lists are session reads,
  ## so a tournament must not grow a social badge the profile cannot show.
  for playerId in side:
    var entry = result.mgetOrPut(playerId, GameTally())
    inc entry.games
    if won:
      inc entry.wins
    result[playerId] = entry

proc loadGames(conn: DbConn, communityId: string): Table[string, GameTally] =
  ## Played games of approved sessions. Each side is tallied separately so wins
  ## and the distinct partner/opponent sets come from one pass. The gate is the
  ## rating gate: a game needs a present player on both sides, and a skipped
  ## player takes no part in it, not even as a partner or an opponent.
  let absent = loadAbsent(conn, communityId)
  let skipped = loadSkips(conn, communityId)
  for row in conn.query(
    """select r.session_id::text as session_id,
              r.round_no as round_no, r.court_no as court_no,
              r.winner as winner,
              coalesce(r.side_a1::text, '') as a1,
              coalesce(r.side_a2::text, '') as a2,
              coalesce(r.side_b1::text, '') as b1,
              coalesce(r.side_b2::text, '') as b2
       from session.game_results r
       join session.sessions s
         on s.community_id = r.community_id and s.id = r.session_id
       where r.community_id = $1::uuid and r.status = 'played'
         and r.winner <> ''
         and s.approved_at is not null
         and s.status in """ & approvedStatuses,
    @[textParam(communityId)]):
    let sessionId = row.getUuid("session_id")
    let gameKey = row.get("round_no") & "-" & row.get("court_no")
    let split = sides(row.get("a1"), row.get("a2"), row.get("b1"),
      row.get("b2"), absent.getOrDefault(sessionId),
      skipped.getOrDefault(sessionId).getOrDefault(gameKey))
    if not split.counts:
      continue
    let aWon = row.get("winner") == "a"
    result.tallySide(split.eligibleA, split.eligibleB, aWon)
    result.tallySide(split.eligibleB, split.eligibleA, not aWon)

  # A tournament counts only once it was ingested: `player_state`, which the
  # profile shows, is written by the event, so a running bracket must not award
  # a badge the profile cannot explain. Classic matches count one game per pair
  # and team matches one game per scored partai, exactly like the ledger.
  for row in conn.query(
    """select coalesce(pa.player_a_id::text, '') as a1,
              coalesce(pa.player_b_id::text, '') as a2,
              coalesce(pb.player_a_id::text, '') as b1,
              coalesce(pb.player_b_id::text, '') as b2,
              m.score_a as score_a, m.score_b as score_b
       from tournament.matches m
       join tournament.pairs pa
         on pa.community_id = m.community_id and pa.id = m.pair_a_id
       join tournament.pairs pb
         on pb.community_id = m.community_id and pb.id = m.pair_b_id
       join rating.events e
         on e.community_id = m.community_id
        and e.source_id = m.tournament_id and e.event_type = 'tournament'
       where m.community_id = $1::uuid
         and m.score_a is not null and m.score_b is not null""",
    @[textParam(communityId)]):
    var sideA, sideB: seq[string] = @[]
    for key in ["a1", "a2"]:
      if row.get(key).len > 0:
        sideA.add(row.get(key))
    for key in ["b1", "b2"]:
      if row.get(key).len > 0:
        sideB.add(row.get(key))
    if sideA.len == 0 or sideB.len == 0:
      continue
    let aWon = row.getInt("score_a") > row.getInt("score_b")
    result.tallyResult(sideA, aWon)
    result.tallyResult(sideB, not aWon)
  var rosters = initTable[string, seq[(string, string)]]()
  for row in conn.query(
    """select team_id::text as team_id, cls, player_id::text as player_id
       from tournament.team_players
       where community_id = $1::uuid and player_id is not null""",
    @[textParam(communityId)]):
    rosters.mgetOrPut(row.getUuid("team_id"), @[]).add(
      (row.get("cls"), row.getUuid("player_id")))
  for row in conn.query(
    """select tm.team_a_id::text as team_a, tm.team_b_id::text as team_b,
              p.partai_index as partai_index,
              p.score_a as score_a, p.score_b as score_b
       from tournament.team_partai p
       join tournament.team_matches tm
         on tm.community_id = p.community_id and tm.id = p.team_match_id
       join rating.events e
         on e.community_id = tm.community_id
        and e.source_id = tm.tournament_id and e.event_type = 'tournament'
       where p.community_id = $1::uuid
         and p.score_a is not null and p.score_b is not null
         and tm.team_a_id is not null and tm.team_b_id is not null""",
    @[textParam(communityId)]):
    let index = row.getInt("partai_index")
    let teamA = rosters.getOrDefault(row.getUuid("team_a"))
    let teamB = rosters.getOrDefault(row.getUuid("team_b"))
    let sideA = sideForPartai(teamA, index)
    let sideB = sideForPartai(teamB, index)
    if sideA.len == 0 or sideB.len == 0:
      continue
    let aWon = row.getInt("score_a") > row.getInt("score_b")
    result.tallyResult(sideA, aWon)
    result.tallyResult(sideB, not aWon)

proc loadTournaments(conn: DbConn, communityId: string): Table[string, int] =
  ## Tournament appearances, classic pairs and team rosters alike: a team
  ## tournament names its players in `tournament.team_players`, so reading
  ## `pairs` alone would hide every team event from the tournament medals.
  for row in conn.query(
    """select entry.player_id as player_id,
              count(distinct entry.tournament_id)::int as played
       from (
         select player_a_id as player_id, tournament_id
         from tournament.pairs where community_id = $1::uuid
         union all
         select player_b_id as player_id, tournament_id
         from tournament.pairs where community_id = $1::uuid
         union all
         select tp.player_id as player_id, t.tournament_id
         from tournament.team_players tp
         join tournament.teams t
           on t.community_id = tp.community_id and t.id = tp.team_id
         where tp.community_id = $1::uuid and tp.player_id is not null
       ) entry
       where entry.player_id is not null
       group by entry.player_id""",
    @[textParam(communityId)]):
    result[row.getUuid("player_id")] = row.getInt("played")

proc loadTiers(conn: DbConn, communityId: string): Table[string, int] =
  for row in conn.query(
    """select id, coalesce(tier, '') as tier from player.players
       where community_id = $1::uuid""",
    @[textParam(communityId)]):
    result[row.getUuid("id")] = tierLevel(row.get("tier"))

proc loadRanks(db: Db, communityId, asOf: string,
               params: RatingParams): Table[string, int] =
  ## Current standing read from the same board query the member page uses, so a
  ## rank badge can never disagree with the ranked list. Only players with an
  ## entry inside the window are ranked, so a newcomer has no rank badge, and a
  ## community with nothing rated yet has no board at all.
  if asOf.len == 0:
    return
  for row in board(db, BoardQuery(communityId: communityId, asOf: asOf,
    params: params, limit: 0)):
    result[row.playerId] = row.rank

proc loadRankStreaks(conn: DbConn,
                     communityId: string): Table[string, RankStreak] =
  ## The v1 `rank_streak` medal: the longest run of consecutive event dates on
  ## which the player sat at rank 3 or better. The sequence is the community's
  ## distinct event dates, not calendar days, so a week without a match neither
  ## extends nor breaks a run, and a date with no snapshot row for the player
  ## breaks it: an unrecorded rank is not evidence of staying on top. Only rows
  ## carrying a rank count, which is why the history starts when `ranksnapshot`
  ## began writing the column rather than with the earliest event.
  var dates: seq[string] = @[]
  for row in conn.query(
    """select distinct local_date::text as day from rating.events
       where community_id = $1::uuid order by 1""",
    @[textParam(communityId)]):
    dates.add(row.get("day"))
  var placed = initTable[string, Table[string, int]]()
  for row in conn.query(
    """select s.player_id::text as player_id, s.taken_on::text as day,
              s.rank as rank
       from rating.snapshots s
       where s.community_id = $1::uuid and s.rank is not null
         and s.taken_on in (
           select local_date from rating.events where community_id = $1::uuid)""",
    @[textParam(communityId)]):
    placed.mgetOrPut(row.get("day"), initTable[string, int]())[
      row.getUuid("player_id")] = row.getInt("rank")
  var run = initTable[string, int]()
  for day in dates:
    let today = placed.getOrDefault(day)
    # A player with no row today had an unknown rank, so the run stops instead
    # of continuing on the assumption that they were still near the top.
    var broken: seq[string] = @[]
    for playerId in run.keys:
      if not today.hasKey(playerId):
        broken.add(playerId)
    for playerId in broken:
      run.del(playerId)
    for playerId, rank in today:
      if rank <= 0 or rank > streakRankThreshold:
        run.del(playerId)
        continue
      let length = run.getOrDefault(playerId) + 1
      run[playerId] = length
      if length > result.getOrDefault(playerId).best:
        result[playerId] = RankStreak(best: length, endedOn: day)

proc loadFacts(conn: DbConn, communityId: string,
               ranks: Table[string, int]): seq[Facts] =
  ## The roster drives the loop, so a player with no sessions still appears
  ## (and earns nothing).
  let attendance = loadAttendance(conn, communityId)
  let games = loadGames(conn, communityId)
  let tournaments = loadTournaments(conn, communityId)
  let tiers = loadTiers(conn, communityId)
  let streaks = loadRankStreaks(conn, communityId)
  for playerId, level in tiers:
    let attended = attendance.getOrDefault(playerId)
    let tally = games.getOrDefault(playerId)
    let streak = streaks.getOrDefault(playerId)
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
      rank: ranks.getOrDefault(playerId),
      rankStreak: streak.best,
      rankStreakEnd: streak.endedOn))

proc catalogKeys(): seq[string] =
  for badge in catalog():
    result.add(badge.key)

proc quotedKeys(keys: seq[string]): string =
  ## The list comes from `catalog()`, a code constant of key strings, so a
  ## quoted literal is fine here and avoids array-parameter plumbing.
  var quoted: seq[string] = @[]
  for key in keys:
    quoted.add("'" & key & "'")
  quoted.join(", ")

proc loadEarned(conn: DbConn, communityId: string,
                keys: seq[string]): Table[string, seq[string]] =
  ## One read of the rows actually on the shelf, so the reconciliation can tell
  ## what went stale instead of asking the database once per player. The
  ## `rank_streak:*` family is read alongside the catalog because the writer
  ## keeps one row per player and needs the value already recorded; imported
  ## `tournament:<uuid>` rows stay outside this set and are never revoked.
  for row in conn.query(
    """select player_id::text as player_id, achievement_key as key
       from achievement.earned
       where community_id = $1::uuid
         and (achievement_key in (""" & quotedKeys(keys) & """)
              or left(achievement_key, 12) = 'rank_streak:')""",
    @[textParam(communityId)]):
    result.mgetOrPut(row.getUuid("player_id"), @[]).add(row.get("key"))

proc loadImported(conn: DbConn, communityId: string): HashSet[string] =
  ## Rows a v1 import wrote, keyed by player and badge. They are history, not a
  ## fact this pass computed, so the reconciliation leaves them alone: the games
  ## behind a v1 badge may not all have survived the import, and dropping the
  ## badge would erase what the members already earned.
  for row in conn.query(
    """select player_id::text as player_id, achievement_key as key
       from achievement.earned
       where community_id = $1::uuid and meta->>'source' = 'v1'""",
    @[textParam(communityId)]):
    result.incl(row.getUuid("player_id") & "|" & row.get("key"))

proc revokeAwards(conn: DbConn, communityId: string,
                  earned, qualified: Table[string, seq[string]],
                  imported: HashSet[string]): int =
  ## A key the player no longer qualifies for is revoked, the rank-streak
  ## family included: its qualified set holds the single highest run, so the
  ## lower milestones of the same family are cleared. Imported
  ## `tournament:<uuid>` event medals are not read here, so they survive
  ## whatever the v2 rules say; catalog badges a v1 import wrote are skipped for
  ## the same reason.
  var stale: seq[(string, string)] = @[]
  for playerId, keys in earned:
    let live = qualified.getOrDefault(playerId)
    for key in keys:
      if key notin live and (playerId & "|" & key) notin imported:
        stale.add((playerId, key))
  const chunk = 100
  var start = 0
  while start < stale.len:
    let last = min(start + chunk, stale.len)
    var params = @[textParam(communityId)]
    var tuples: seq[string] = @[]
    for index in start ..< last:
      let base = params.len + 1
      tuples.add("($" & $base & "::uuid, $" & $(base + 1) & ")")
      params.add(textParam(stale[index][0]))
      params.add(textParam(stale[index][1]))
    result += conn.execUpdate(
      """delete from achievement.earned
         where community_id = $1::uuid
           and (player_id, achievement_key) in (""" & tuples.join(", ") & ")",
      params)
    start = last

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

proc backfill*(db: Db, communityId, asOf: string,
               params: RatingParams): BackfillResult =
  ## Awards every threshold the current data qualifies for and revokes the
  ## catalog keys it no longer does, so the shelf is reconciled with the same
  ## facts the board reads. The rank-streak family is reconciled too, since v2
  ## owns it; a player's best run yields exactly one row. Idempotent: a badge
  ## that already exists keeps its original `earned_at`, and only the players
  ## whose facts moved gain or lose rows. `asOf` and `params` are the board
  ## read's inputs, so `rank:N` is measured on the best-N window the members
  ## see; the board is read before the transaction because the pool hands this
  ## process a single connection.
  var outcome: BackfillResult
  let ranks = loadRanks(db, communityId, asOf, params)
  db.tx(proc(conn: DbConn) =
    let facts = loadFacts(conn, communityId, ranks)
    let keys = catalogKeys()
    let earnedAt = utcNow().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    let earned = loadEarned(conn, communityId, keys)
    let imported = loadImported(conn, communityId)
    var qualified = initTable[string, seq[string]]()
    var rows: seq[EarnRow] = @[]
    for item in facts:
      var awarded = awardedKeys(item)
      # `rank_streak` stays out of the catalog on purpose: the catalog holds
      # rungs (3/5/8/12/16) while the row stores the player's best run, which
      # may sit between rungs. The definition rows only feed the ladder the
      # shelf renders, so the family is appended here instead of being measured
      # by `qualifies`.
      #
      # The recorded rows count towards the best: a v1 import stored the run
      # the old board measured, and v2 starts its own history at the migration,
      # so a fresh run must not report less than the badge already on the
      # shelf. Keeping the maximum also leaves exactly one row per player.
      var best = item.rankStreak
      for key in earned.getOrDefault(item.playerId):
        if key.startsWith(rankStreakPrefix):
          best = max(best, parseInt(key[rankStreakPrefix.len .. ^1]))
      if best >= streakMinLength:
        awarded.add(rankStreakPrefix & $best)
      qualified[item.playerId] = awarded
      for key in awarded:
        rows.add(EarnRow(playerId: item.playerId, key: key))
    outcome.revoked = revokeAwards(conn, communityId, earned, qualified,
      imported)
    outcome.players = facts.len
    outcome.awarded = writeAwards(conn, communityId, earnedAt, rows))
  outcome

proc backfill*(db: Db, communityId: string): BackfillResult =
  ## Resolves the board inputs from the config registry for callers that have
  ## none at hand (the v1 import). The ticker passes the params it already
  ## loaded, so a tick does not read the registry twice.
  backfill(db, communityId, latestEventDate(db, communityId),
    loadRatingParams(loadSnapshot(db), communitySettings(db, communityId)))

proc suffixThreshold(key: string): int =
  try:
    parseInt(keySuffix(key))
  except ValueError:
    0

proc countForPlayer*(db: Db, communityId, playerId: string): int =
  let row = db.queryOne(
    """select count(*)::int as total from achievement.earned
       where community_id = $1::uuid and player_id = $2::uuid""",
    @[textParam(communityId), textParam(playerId)])
  if row.isSome: parseInt(row.get.get("total")) else: 0

proc listForPlayer*(db: Db, communityId, playerId: string, limit,
                    offset: int): seq[JsonNode] =
  ## Newest first; the key breaks ties so the order is stable within a run.
  ## Catalog keys read their ladder from `achievement.definitions`; imported v1
  ## event medals (`tournament:<id>`) and the rank-streak badge have no
  ## definition row, so they fall back to the key and the stored meta.
  var ladders = initTable[string, seq[int]]()
  for row in db.query(
    """select key, threshold from achievement.definitions order by key"""):
    ladders.mgetOrPut(keyMetric(row.get("key")), @[]).add(
      row.getInt("threshold"))
  for row in db.query(
    """select e.achievement_key as key, d.category as category,
              d.threshold as threshold, e.earned_at::text as earned_at,
              e.meta::text as meta
       from achievement.earned e
       left join achievement.definitions d on d.key = e.achievement_key
       where e.community_id = $1::uuid and e.player_id = $2::uuid
       order by e.earned_at desc, e.achievement_key asc
       limit $3 offset $4""",
    @[textParam(communityId), textParam(playerId), intParam(limit.int64),
      intParam(offset.int64)]):
    let key = row.get("key")
    let metric = keyMetric(key)
    let category =
      if row.getOpt("category").isSome: row.get("category")
      elif metric == "tournament": "tournament"
      elif metric == "rank_streak": "rank"
      else: metric
    let threshold =
      if row.getOpt("threshold").isSome: row.getInt("threshold")
      else: suffixThreshold(key)
    let ladder =
      if metric == "tier": @[threshold]
      else: ladderFor(metric, ladders.getOrDefault(metric))
    let level = ladderLevel(metric, threshold, ladder)
    let target = nextTarget(metric, threshold, ladder)
    let nextNode = if target.isSome: %target.get else: newJNull()
    var meta =
      if row.getOpt("meta").isSome and row.get("meta").len > 0:
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
