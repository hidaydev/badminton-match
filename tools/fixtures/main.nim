## Deterministic synthetic data generator for the v1 (`bm`) schema.
##
## The same `--seed` always produces byte-identical SQL: identifiers come from
## a keyed SplitMix64 stream, scores and rotations from the seeded PRNG, and
## every timestamp is derived from a fixed epoch instead of the wall clock.
## Nothing here is production data; names are invented and scores are random.
import std/[os, strutils, times]
import cli

const
  program = "fixtures"
  usage = """Usage: majadu-fixtures [options]

Generate a deterministic v1 dataset (schema `bm`) as one SQL file.

  --seed N    PRNG seed (default: 7)
  --out PATH  output file (.sql) or directory (default: ops/dev/v1/fixtures)
  -h, --help  show this help

The output is stable for a given seed: identical bytes on every run and every
machine. Apply it with psql after ops/dev/v1/schema.sql."""

  defaultSeed = 7
  defaultDir = "ops/dev/v1/fixtures"
  defaultFile = "v1-fixtures.sql"
  playerCount = 12
  epoch = "2026-09-01 00:00:00+00:00"

  namePool = [
    "Andi", "Budi", "Chandra", "Dewi", "Eka", "Fajar", "Gita", "Hadi",
    "Indra", "Jaka", "Kartika", "Lina", "Made", "Nadia", "Oki", "Putri",
    "Raka", "Sari", "Tono", "Umi", "Vino", "Wulan", "Yoga", "Zaki",
  ]

  tierText = ["D", "D+", "C", "C+", "B", "B+", "A", "A+"]
  aliasTags = ["kecil", "besar", "pagi", "malam"]
  achievementKinds = ["attendance", "volume", "tournament", "rank"]
  teamNames = ["Alpha", "Bravo", "Charlie", "Delta"]
  teamClasses = ["A+", "A", "B+", "B"]

  # One namespace per table keeps identifiers distinct without a global table.
  nsPlayer = 1
  nsAchievement = 2
  nsEvent = 3
  nsSession = 4
  nsCourt = 5
  nsSessionPlayer = 6
  nsGame = 7
  nsGamePlayer = 8
  nsFixMatch = 9
  nsTournament = 10
  nsPair = 11
  nsMatch = 12
  nsTeam = 13
  nsTeamPlayer = 14
  nsTeamMatch = 15
  nsTeamGame = 16

  v1Tables = [
    "bm.outbox_events", "bm.idempotency_keys", "bm.fix_matches",
    "bm.scheduled_game_players", "bm.scheduled_games", "bm.session_courts",
    "bm.session_players", "bm.sessions", "bm.rating_deltas", "bm.rating_events",
    "bm.rating_sources", "bm.rating_players", "bm.rank_snapshots",
    "bm.rank_point_levels", "bm.rating_config", "bm.player_achievements",
    "bm.player_aliases", "bm.players", "bm.tournament_team_match_games",
    "bm.tournament_team_matches", "bm.tournament_team_players",
    "bm.tournament_teams", "bm.tournament_groups", "bm.tournament_matches",
    "bm.tournament_pair_players", "bm.tournament_pairs", "bm.tournaments",
  ]

type
  Options = object
    seed: uint64
    outPath: string

  Rng = object
    state: uint64

  Player = object
    id, name, tier, gender, registeredAt: string
    tierIndex: int

  Session = object
    id, shareCode, title, date, startTime, status, source: string
    slotMinutes, tierCount, version: int
    includeAbsent, includeTierCount: bool
    createdAt, updatedAt: string

  SessionPlayer = object
    id, playerRef, sourceName, gender, createdAt, updatedAt: string
    playerIndex, sortOrder, tier: int
    isAbsent: bool
    absentOrder: int

  Game = object
    id, status: string
    slot, court, legacyOrder: int
    isPlayed: bool
    playedOrder: int
    scoreA, scoreB: int
    hasScore: bool
    members: seq[int]

# Exported for tools/fixtures/tests (D-5, TL-01). The generator is a program, so
# these are the seams that let the suite compare the output without writing a
# committed fixture and without a second `nim c` for every case.
proc parseArgs*(): Options =
  result.seed = uint64(defaultSeed)
  result.outPath = defaultDir
  for (flag, value) in flags(program, 1, ["--seed", "--out"]):
    case flag
    of "--seed":
      try:
        let seed = parseBiggestInt(value)
        if seed < 0:
          fail(program, "--seed must not be negative")
        result.seed = uint64(seed)
      except ValueError:
        fail(program, "--seed is not a number: " & value)
    of "--out":
      result.outPath = value
    of "-h", "--help":
      echo usage
      quit(0)
    else:
      usageFail(program, "unknown argument: " & flag)

proc outputFile*(path: string): string =
  if splitFile(path).ext.toLowerAscii() == ".sql":
    path
  else:
    path / defaultFile

# --- deterministic primitives ------------------------------------------------

proc next(rng: var Rng): uint64 =
  ## SplitMix64: stable across Nim versions and platforms.
  rng.state = rng.state + 0x9E3779B97F4A7C15'u64
  var z = rng.state
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc below(rng: var Rng, bound: int): int =
  int(rng.next() mod uint64(bound))

proc uuidFor*(seed: uint64; namespace, index: int): string =
  ## Keyed UUIDv4-shaped identifier: same inputs, same text, always.
  var rng = Rng(state: seed xor (uint64(namespace) * 0x9E3779B97F4A7C15'u64) xor
    (uint64(index) * 0xD6E8FEB86659FD93'u64))
  let hi = rng.next()
  let lo = rng.next()
  var bytes: array[16, byte]
  for i in 0 ..< 8:
    bytes[i] = byte((hi shr (56 - i * 8)) and 0xFF)
    bytes[8 + i] = byte((lo shr (56 - i * 8)) and 0xFF)
  bytes[6] = (bytes[6] and 0x0F) or 0x40
  bytes[8] = (bytes[8] and 0x3F) or 0x80
  const digits = "0123456789abcdef"
  for i in 0 ..< 16:
    if i in [4, 6, 8, 10]:
      result.add '-'
    result.add digits[int(bytes[i] shr 4)]
    result.add digits[int(bytes[i] and 0x0F)]

# --- literal helpers ---------------------------------------------------------

# The committed fixture was generated on a machine in the club's timezone, so
# its wall clock is WIB. Parsing in local time reproduced that on a WIB host and
# produced 00:00 on a UTC runner, which broke the promise that the same seed
# writes a byte-identical file everywhere. The offset is fixed here instead. The
# literal keeps the `+00:00` suffix `stampAt` writes, so those timestamps are WIB
# wall clock labelled as UTC; that is the shape the committed file has always
# had, and regenerating it would change the data.
let base = parse(epoch, "yyyy-MM-dd HH:mm:sszzz", utc()) +
  initDuration(hours = 7)

proc dateAt(day: int): string =
  (base + initDuration(days = day)).format("yyyy-MM-dd")

proc stampAt(day, minute: int): string =
  (base + initDuration(days = day, minutes = minute)).format(
    "yyyy-MM-dd HH:mm:ss") & "+00:00"

proc lit(value: string): string =
  "'" & value.replace("'", "''") & "'"

proc jsonLit(value: string): string =
  lit(value) & "::jsonb"

proc dateLit(day: int): string =
  lit(dateAt(day))

proc stampLit(day, minute: int): string =
  lit(stampAt(day, minute))

proc boolLit(value: bool): string =
  if value: "true" else: "false"

proc nullable(value: int): string =
  if value < 0: "null" else: $value

proc emitInsert(sql: var seq[string]; table: string; columns: openArray[string];
                rows: seq[seq[string]]) =
  if rows.len == 0:
    return
  sql.add "insert into " & table & " (" & columns.join(", ") & ") values"
  for i, row in rows:
    sql.add "  (" & row.join(", ") & ")" & (if i == rows.high: ";" else: ",")
  sql.add ""

proc scorePair(rng: var Rng): (int, int) =
  let loser = 12 + rng.below(9)
  if rng.below(2) == 0:
    (21, loser)
  else:
    (loser, 21)

# --- generation --------------------------------------------------------------

proc buildSql*(seed: uint64): string =
  var rng = Rng(state: seed xor 0x5DEECE66D'u64)
  var sql: seq[string]

  sql.add "-- Synthetic v1 fixture for the local v1 environment."
  sql.add "-- Generated by tools/fixtures; do not edit by hand."
  sql.add "-- seed: " & $seed & ", players: " & $playerCount
  sql.add ""
  sql.add "begin;"
  sql.add ""
  sql.add "truncate table"
  sql.add "  " & v1Tables.join(",\n  ")
  sql.add "  restart identity cascade;"
  sql.add ""

  # players
  let nameShift = int(seed mod uint64(namePool.len))
  var players: seq[Player]
  for i in 0 ..< playerCount:
    let tierIndex = (i * 3 + int(seed mod 8)) mod 8
    players.add Player(
      id: uuidFor(seed, nsPlayer, i),
      name: namePool[(i + nameShift) mod namePool.len],
      tier: tierText[tierIndex],
      tierIndex: tierIndex + 1,
      gender: (if (i + int(seed)) mod 2 == 0: "M" else: "F"),
      registeredAt: dateAt(-400 + i * 10),
    )

  block:
    var rows: seq[seq[string]]
    for i, player in players:
      rows.add @[
        lit(player.id), lit(player.name), stampLit(-400 + i * 10, 0),
        stampLit(-400 + i * 10, 5), lit(player.tier), lit(player.registeredAt),
        lit(player.gender)
      ]
    sql.emitInsert("bm.players", ["id", "canonical_name", "created_at",
      "updated_at", "tier", "registered_at", "gender"], rows)

  block:
    var rows: seq[seq[string]]
    for i, player in players:
      if i mod 3 == 0:
        let alias = player.name.toLowerAscii & " " &
          aliasTags[(i div 3) mod aliasTags.len]
        rows.add @[lit(alias), lit(player.id), stampLit(-380 + i * 10, 0)]
    sql.emitInsert("bm.player_aliases", ["alias_name", "player_id",
      "created_at"], rows)

  block:
    var rows: seq[seq[string]]
    for i, player in players:
      let kind = achievementKinds[(i + int(seed mod 4)) mod achievementKinds.len]
      rows.add @[
        lit(uuidFor(seed, nsAchievement, i)), lit(player.id),
        lit(kind & "-" & $(10 + i mod 5)), lit(kind), dateLit(40 + i),
        $(10 + i), jsonLit("{}"), stampLit(40 + i, i), stampLit(40 + i, i)
      ]
    sql.emitInsert("bm.player_achievements", ["id", "player_id",
      "achievement_key", "kind", "earned_at", "value", "meta", "created_at",
      "updated_at"], rows)

  block:
    var rows: seq[seq[string]]
    for i, player in players:
      rows.add @[dateLit(70), lit(player.id), $(i + 1), $(1000 - i * 37),
        stampLit(70, i)]
    sql.emitInsert("bm.rank_snapshots", ["as_of", "player_id", "rank", "points",
      "captured_at"], rows)

  block:
    let levels = [
      ("monthly", "120", """{"champion":1,"final":0.6,"sf":0.4}"""),
      ("season", "500", """{"champion":1,"final":0.6,"sf":0.4}"""),
    ]
    var rows: seq[seq[string]]
    for i, (kind, points, ratios) in levels:
      rows.add @[lit(kind), points, jsonLit(ratios), boolLit(true),
        stampLit(-60, i), stampLit(-60, i)]
    sql.emitInsert("bm.rank_point_levels", ["kind", "champion_points",
      "round_ratios", "enabled", "created_at", "updated_at"], rows)

  block:
    let configs = [
      ("k_factor", """{"default":32}"""),
      ("provisional_games", """{"count":10}"""),
      ("scale", """{"min":0.5,"max":2.0}"""),
    ]
    var rows: seq[seq[string]]
    for i, (key, value) in configs:
      rows.add @[lit(key), jsonLit(value), stampLit(-60, i)]
    sql.emitInsert("bm.rating_config", ["key", "value", "updated_at"], rows)

  # sessions
  let sessions = [
    Session(
      id: uuidFor(seed, nsSession, 1), shareCode: "v1demo0001",
      title: "Tuesday Night", date: dateAt(56), startTime: "19:00:00",
      slotMinutes: 30, status: "published", source: "manual", tierCount: 8,
      includeAbsent: false, includeTierCount: true, version: 3,
      createdAt: stampAt(50, 0), updatedAt: stampAt(56, 120)),
    Session(
      id: uuidFor(seed, nsSession, 2), shareCode: "v1demo0002",
      title: "Draft Thursday", date: dateAt(63), startTime: "19:30:00",
      slotMinutes: 30, status: "draft", source: "manual", tierCount: 6,
      includeAbsent: false, includeTierCount: false, version: 1,
      createdAt: stampAt(60, 0), updatedAt: stampAt(60, 5)),
  ]

  block:
    var rows: seq[seq[string]]
    for session in sessions:
      rows.add @[lit(session.id), lit(session.shareCode), lit(session.title),
        lit(session.date), lit(session.startTime), $session.slotMinutes,
        lit(session.status), lit(session.source), lit(session.createdAt),
        lit(session.updatedAt), $session.tierCount,
        boolLit(session.includeAbsent), boolLit(session.includeTierCount),
        $session.version]
    sql.emitInsert("bm.sessions", ["id", "share_code", "title", "session_date",
      "session_start", "slot_minutes", "status", "source", "created_at",
      "updated_at", "session_tier_count", "include_absent_players",
      "include_tier_count", "version"], rows)

  block:
    var rows: seq[seq[string]]
    rows.add @[lit(sessions[0].id), "0", lit("Court 1"), lit("19:00:00"),
      lit("21:00:00"), lit(uuidFor(seed, nsCourt, 0))]
    rows.add @[lit(sessions[0].id), "1", lit("Court 2"), lit("19:00:00"),
      lit("21:00:00"), lit(uuidFor(seed, nsCourt, 1))]
    rows.add @[lit(sessions[1].id), "0", lit("Court 1"), lit("19:30:00"),
      lit("21:30:00"), lit(uuidFor(seed, nsCourt, 2))]
    sql.emitInsert("bm.session_courts", ["session_id", "court_index",
      "court_name", "start_time", "end_time", "internal_id"], rows)

  proc buildSessionPlayers(group: int; startPlayer, count, day: int):
      seq[SessionPlayer] =
    for i in 0 ..< count:
      let player = players[startPlayer + i]
      let absent = group == 2 and i == count - 1
      result.add SessionPlayer(
        id: uuidFor(seed, nsSessionPlayer, group * 100 + i),
        playerRef: "p" & $(i + 1),
        sourceName: player.name,
        playerIndex: startPlayer + i,
        sortOrder: i,
        gender: player.gender,
        tier: player.tierIndex,
        isAbsent: absent,
        absentOrder: (if absent: 0 else: -1),
        createdAt: stampAt(day, 0),
        updatedAt: stampAt(day, 5),
      )

  let sessionPlayers1 = buildSessionPlayers(1, 0, 8, 55)
  let sessionPlayers2 = buildSessionPlayers(2, 6, 6, 62)

  block:
    var rows: seq[seq[string]]
    for group in 0 .. 1:
      let groupPlayers = if group == 0: sessionPlayers1 else: sessionPlayers2
      for sp in groupPlayers:
        rows.add @[lit(players[sp.playerIndex].id), lit(sp.playerRef),
          lit(sp.sourceName), $sp.sortOrder, lit(sp.gender), $sp.tier,
          boolLit(sp.isAbsent), lit(""), lit(sp.createdAt), lit(sp.updatedAt),
          nullable(sp.absentOrder), lit(sessions[group].id), lit(sp.id)]
    sql.emitInsert("bm.session_players", ["player_id", "player_ref",
      "source_name", "sort_order", "gender", "tier", "is_absent",
      "replacement_note", "created_at", "updated_at", "absent_order",
      "session_id", "internal_id"], rows)

  # scheduled games for the published session
  var games: seq[Game]
  for slot in 0 ..< 4:
    for court in 0 ..< 2:
      let index = slot * 2 + court
      var game = Game(
        id: uuidFor(seed, nsGame, index),
        slot: slot,
        court: court,
        legacyOrder: index + 1,
        playedOrder: (if index < 5: index + 1 else: -1),
        isPlayed: index < 5,
      )
      if index < 5:
        game.status = "played"
        let (a, b) = scorePair(rng)
        game.scoreA = a
        game.scoreB = b
        game.hasScore = true
      elif index == 6:
        game.status = "cancelled"
      else:
        game.status = "scheduled"
      let start = (index * 2) mod sessionPlayers1.len
      for k in 0 ..< 4:
        game.members.add((start + k) mod sessionPlayers1.len)
      games.add game

  proc gamePlayersRows(games: seq[Game]): seq[seq[string]] =
    for game in games:
      for k, member in game.members:
        let team = if k < 2: "A" else: "B"
        let position = if k mod 2 == 0: 0 else: 1
        result.add @[
          lit(team), $position, lit(game.id),
          lit(sessionPlayers1[member].id),
          lit(uuidFor(seed, nsGamePlayer, game.legacyOrder * 10 + k))
        ]

  block:
    var rows: seq[seq[string]]
    for game in games:
      rows.add @[lit(sessions[0].id), $game.slot, $game.court, lit(game.status),
        lit("generator"), lit(stampAt(50, game.legacyOrder)),
        lit(stampAt(56, game.legacyOrder)), $game.legacyOrder, boolLit(game.isPlayed),
        nullable(game.playedOrder),
        (if game.hasScore: $game.scoreA else: "null"),
        (if game.hasScore: $game.scoreB else: "null"),
        lit("{}"), "1", lit(game.id)]
    sql.emitInsert("bm.scheduled_games", ["session_id", "slot_index",
      "court_index", "status", "source", "created_at", "updated_at",
      "legacy_order", "is_played", "played_order", "score_a", "score_b",
      "skipped_player_refs", "version", "internal_id"], rows)

  sql.emitInsert("bm.scheduled_game_players", ["team", "position",
    "scheduled_game_internal_id", "session_player_internal_id", "internal_id"],
    gamePlayersRows(games))

  block:
    var rows: seq[seq[string]]
    for i in 0 ..< 2:
      var slots: array[4, string]
      for k in 0 ..< 4:
        slots[k] = lit(sessionPlayers1[i * 4 + k].id)
      rows.add @[lit("fix-" & $(i + 1)), $i, lit(stampAt(55, i)),
        lit(stampAt(55, i + 1)), lit(sessions[0].id),
        lit(uuidFor(seed, nsFixMatch, i)), slots[0], slots[1], slots[2],
        slots[3]]
    sql.emitInsert("bm.fix_matches", ["legacy_ref", "sort_order", "created_at",
      "updated_at", "session_id", "internal_id", "slot_0", "slot_1", "slot_2",
      "slot_3"], rows)

  # rating pipeline for the played games
  var played: seq[Game]
  for game in games:
    if game.isPlayed:
      played.add game

  block:
    var rows: seq[seq[string]]
    rows.add @[lit("session:v1demo0001"), lit("session"),
      lit("fp-session-v1demo0001"), boolLit(true), $played.len,
      stampLit(56, 200)]
    sql.emitInsert("bm.rating_sources", ["source_id", "source_kind",
      "fingerprint", "finalized", "last_ingested_seq", "ingested_at"], rows)

  block:
    var rows: seq[seq[string]]
    for i, game in played:
      rows.add @[
        lit(uuidFor(seed, nsEvent, i)),
        lit("session/v1demo0001/g" & $game.legacyOrder), $(i + 1), lit("session"),
        lit("session:v1demo0001"), lit("fp-session-v1demo0001-g" & $game.legacyOrder),
        lit(game.id), dateLit(56), stampLit(56, 60 + i),
        $game.legacyOrder, lit("Tuesday Night"), $game.scoreA, $game.scoreB,
        "21", lit("session"), stampLit(56, 100 + i)
      ]
    sql.emitInsert("bm.rating_events", ["id", "match_key", "seq", "kind",
      "source_id", "source_fingerprint", "stable_game_id", "date", "created_at",
      "game_order", "title", "score_a", "score_b", "target", "phase",
      "processed_at"], rows)

  block:
    var rows: seq[seq[string]]
    for i, game in played:
      let eventId = uuidFor(seed, nsEvent, i)
      for k, member in game.members:
        let team = if k < 2: "A" else: "B"
        let teamWon = (team == "A" and game.scoreA > game.scoreB) or
          (team == "B" and game.scoreB > game.scoreA)
        rows.add @[lit(eventId), lit(players[sessionPlayers1[member].playerIndex].id),
          lit(team), lit(if teamWon: "W" else: "L")]
    sql.emitInsert("bm.rating_deltas", ["event_id", "player_id", "team",
      "outcome"], rows)

  block:
    var appearances = newSeq[int](playerCount)
    var wins = newSeq[int](playerCount)
    var losses = newSeq[int](playerCount)
    for game in played:
      for k, member in game.members:
        let playerIndex = sessionPlayers1[member].playerIndex
        let team = if k < 2: "A" else: "B"
        let teamWon = (team == "A" and game.scoreA > game.scoreB) or
          (team == "B" and game.scoreB > game.scoreA)
        appearances[playerIndex] = appearances[playerIndex] + 1
        if teamWon:
          wins[playerIndex] = wins[playerIndex] + 1
        else:
          losses[playerIndex] = losses[playerIndex] + 1
    var rows: seq[seq[string]]
    for i, player in players:
      rows.add @[lit(player.id), $appearances[i], $wins[i], $losses[i],
        (if appearances[i] > 0: dateLit(56) else: "null"),
        stampLit(56, 300), stampLit(56, 300)]
    sql.emitInsert("bm.rating_players", ["player_id", "games_played", "wins",
      "losses", "last_played_at", "created_at", "updated_at"], rows)

  block:
    var rows: seq[seq[string]]
    rows.add @[lit(sessions[0].id), lit("seed-publish"),
      jsonLit("""{"share_code":"v1demo0001"}"""), stampLit(56, 1),
      stampLit(66, 1)]
    rows.add @[lit(sessions[0].id), lit("seed-score"),
      jsonLit("""{"accepted":true}"""), stampLit(56, 2), stampLit(56, 120)]
    sql.emitInsert("bm.idempotency_keys", ["session_id", "key", "response",
      "created_at", "expires_at"], rows)

  block:
    let events = [
      ("session", sessions[0].id, "session.published", """{"version":3}""", "1", 56, 2),
      ("game", games[0].id, "session.game_scored", """{"scoreA":21}""", "2", 56, 3),
      ("tournament", uuidFor(seed, nsTournament, 1), "tournament.updated",
        """{"format":"classic"}""", "2", 54, 0),
      ("tournament", uuidFor(seed, nsTournament, 2), "tournament.updated",
        """{"format":"team"}""", "1", 69, 0),
    ]
    var rows: seq[seq[string]]
    for i, (aggregate, aggregateId, eventType, payload, version, day, minute) in events:
      rows.add @[$(i + 1), lit(sessions[0].id), lit(aggregate), lit(aggregateId),
        lit(eventType), jsonLit(payload), version, stampLit(day, minute)]
    sql.emitInsert("bm.outbox_events", ["id", "session_id", "aggregate",
      "aggregate_id", "event_type", "payload", "version", "created_at"], rows)

  # tournaments
  let tournamentClassic = uuidFor(seed, nsTournament, 1)
  let tournamentTeam = uuidFor(seed, nsTournament, 2)

  block:
    var rows: seq[seq[string]]
    rows.add @[lit("v1tour0001"), lit("Autumn Cup"), dateLit(54),
      stampLit(55, 0), lit(tournamentClassic), "2", stampLit(40, 0),
      lit("classic")]
    rows.add @[lit("v1tour0002"), lit("Team League"), dateLit(69),
      stampLit(69, 0), lit(tournamentTeam), "1", stampLit(60, 0), lit("team")]
    sql.emitInsert("bm.tournaments", ["share_code", "name", "event_date",
      "updated_at", "id", "version", "created_at", "format"], rows)

  var pairIds: seq[string]
  block:
    var rows: seq[seq[string]]
    for i in 0 ..< 6:
      let id = uuidFor(seed, nsPair, i)
      pairIds.add id
      rows.add @[lit(id), lit(tournamentClassic),
        lit(players[i * 2].name & " / " & players[i * 2 + 1].name), $(i + 1)]
    sql.emitInsert("bm.tournament_pairs", ["id", "tournament_id", "pair_name",
      "seed"], rows)

  block:
    var rows: seq[seq[string]]
    for i in 0 ..< 6:
      rows.add @[lit(pairIds[i]), lit(players[i * 2].id)]
      rows.add @[lit(pairIds[i]), lit(players[i * 2 + 1].id)]
    sql.emitInsert("bm.tournament_pair_players", ["pair_id", "player_id"], rows)

  block:
    var rows: seq[seq[string]]
    for i in 0 ..< 6:
      let groupId = if i < 3: "A" else: "B"
      let position = i mod 3
      rows.add @[lit(tournamentClassic), lit(groupId), lit(pairIds[i]),
        $position]
    sql.emitInsert("bm.tournament_groups", ["tournament_id", "group_id",
      "pair_id", "position"], rows)

  block:
    var rows: seq[seq[string]]
    var order = 0
    for groupIndex in 0 ..< 2:
      let groupId = if groupIndex == 0: "A" else: "B"
      let skip = groupIndex * 3
      let pairings = [(0, 1), (1, 2), (2, 0)]
      for i, (a, b) in pairings:
        let (scoreA, scoreB) = scorePair(rng)
        order.inc
        rows.add @[lit(uuidFor(seed, nsMatch, order)), lit(tournamentClassic),
          lit("group"), lit(groupId), lit(pairIds[skip + a]), lit(pairIds[skip + b]),
          $scoreA, $scoreB, lit(players[skip + a].id), $order,
          lit(groupId & "-" & $(i + 1))]
    let knockout = [
      ("sf", 0, 3, "SF-1"), ("sf", 1, 4, "SF-2"),
      ("3rd", 0, 1, "3RD-1"), ("final", 3, 4, "F-1"),
    ]
    for (phase, a, b, key) in knockout:
      let (scoreA, scoreB) = scorePair(rng)
      order.inc
      rows.add @[lit(uuidFor(seed, nsMatch, order)), lit(tournamentClassic),
        lit(phase), "null", lit(pairIds[a]), lit(pairIds[b]), $scoreA, $scoreB,
        lit(players[a].id), $order, lit(key)]
    sql.emitInsert("bm.tournament_matches", ["id", "tournament_id", "phase",
      "group_id", "pair_a_id", "pair_b_id", "score_a", "score_b",
      "pic_player_id", "match_order", "match_key"], rows)

  # team tournament
  var teamIds: seq[string]
  block:
    var rows: seq[seq[string]]
    for i in 0 ..< 4:
      let id = uuidFor(seed, nsTeam, i)
      teamIds.add id
      rows.add @[lit(id), lit(tournamentTeam), $(i + 1), lit(teamNames[i])]
    sql.emitInsert("bm.tournament_teams", ["id", "tournament_id", "seed",
      "team_name"], rows)

  block:
    var rows: seq[seq[string]]
    for team in 0 ..< 4:
      for slot, cls in teamClasses:
        let player = players[(team * 4 + slot) mod players.len]
        rows.add @[lit(uuidFor(seed, nsTeamPlayer, team * 10 + slot)),
          lit(teamIds[team]), lit(player.name), lit(player.id), lit(cls)]
    sql.emitInsert("bm.tournament_team_players", ["id", "team_id",
      "player_name", "player_id", "cls"], rows)

  var teamMatchIds: seq[string]
  block:
    var rows: seq[seq[string]]
    let matches = [("group", 0, 1, "G-1"), ("group", 2, 3, "G-2"),
      ("final", 0, 2, "F-1")]
    for i, (phase, a, b, key) in matches:
      let id = uuidFor(seed, nsTeamMatch, i)
      teamMatchIds.add id
      rows.add @[lit(id), lit(tournamentTeam), lit(phase), $(i + 1), lit(key),
        lit(teamIds[a]), lit(teamIds[b]),
        "array['Court 1', 'Court 2', 'Court 3']"]
    sql.emitInsert("bm.tournament_team_matches", ["id", "tournament_id",
      "phase", "match_order", "match_key", "team_a_id", "team_b_id", "courts"],
      rows)

  block:
    var rows: seq[seq[string]]
    for i, matchId in teamMatchIds:
      for partai in 0 ..< 3:
        let (scoreA, scoreB) = scorePair(rng)
        rows.add @[lit(uuidFor(seed, nsTeamGame, i * 10 + partai)), lit(matchId),
          $partai, $scoreA, $scoreB]
    sql.emitInsert("bm.tournament_team_match_games", ["id", "team_match_id",
      "partai_index", "score_a", "score_b"], rows)

  sql.add "select setval('bm.outbox_events_id_seq', 4, true);"
  sql.add "select setval('bm.rating_events_seq_seq', " & $played.len & ", true);"
  sql.add ""
  sql.add "commit;"
  sql.add ""

  result = sql.join("\n")

proc main() =
  let options = parseArgs()
  let started = cpuTime()
  let path = outputFile(options.outPath)
  createDir(path.parentDir)
  let content = buildSql(options.seed)
  writeFile(path, content)
  let elapsed = (cpuTime() - started) * 1000
  echo "fixtures: seed=" & $options.seed & " players=" & $playerCount &
    " bytes=" & $content.len & " elapsed_ms=" & $int(elapsed)
  echo "fixtures: wrote " & path

when isMainModule:
  main()
