## TL-15: which calendar day a rank snapshot is written for.
##
## `main` walks every community in the database, so it cannot be pointed at one
## scratch community without writing rows for all the others. The day choice is
## therefore the extracted `snapshotDay` (D-5), and the rest of the write path is
## driven exactly as `main` drives it: the config snapshot, the rating params,
## the board and `writeSnapshot`.
##
## The suite owns a community of its own and deletes it in teardown; it never
## touches a seeded community.
import std/[json, options, os, osproc, strutils, tables, unittest]
import community_time
import db/db
import platform/config/store
import rating/infrastructure/params
import rating/read
import ../../main

const
  slug = "rank-snapshot-test"
  timezone = "Asia/Jakarta"

proc repoRoot(): string =
  ## The tool is built from the repository root so `config.nims` supplies the
  ## module paths.
  var dir = currentSourcePath().parentDir
  for _ in 0 ..< 8:
    if fileExists(dir / "tools/ranksnapshot/main.nim"):
      return dir
    let parent = parentDir(dir)
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot find the repository root from " & currentSourcePath())

proc toolBinary(): string =
  ## `./task check` compiles suites, not the tools, so the usage cases drive a
  ## binary built once here. `RANKSNAPSHOT_BIN` lets a run reuse one.
  var built {.global.}: string
  if built.len > 0:
    return built
  let fromEnv = getEnv("RANKSNAPSHOT_BIN")
  if fromEnv.len > 0 and fileExists(fromEnv):
    return fromEnv
  let root = repoRoot()
  let directory = getTempDir() / ("majadu-ranksnapshot-" & $getCurrentProcessId())
  createDir(directory)
  built = directory / "ranksnapshot"
  let (output, code) = execCmdEx("nim c --hints:off --nimcache:" &
    quoteShell(directory / "nimcache") & " -o:" & quoteShell(built) & " " &
    quoteShell(root / "tools/ranksnapshot/main.nim"), workingDir = root)
  if code != 0 or not fileExists(built):
    raise newException(IOError, "cannot build ranksnapshot:\n" & output)
  built

proc runCli(arguments: string): tuple[output: string, exitCode: int] =
  execCmdEx(quoteShell(toolBinary()) & " " & arguments, workingDir = repoRoot())

var
  database: Db
  communityId: string
  players: seq[string]

proc cleanup() =
  # Children first: `rating.events` refers to the community with `on delete
  # restrict`, so dropping the community alone would fail while events remain.
  for statement in [
      """delete from rating.snapshots where community_id in
           (select id from platform.community where slug = $1)""",
      """delete from rating.levels where community_id in
           (select id from platform.community where slug = $1)""",
      """delete from rating.events where community_id in
           (select id from platform.community where slug = $1)""",
      """delete from session.game_sets where community_id in
           (select id from platform.community where slug = $1)""",
      """delete from session.games where community_id in
           (select id from platform.community where slug = $1)""",
      """delete from session.sessions where community_id in
           (select id from platform.community where slug = $1)""",
      """delete from player.players where community_id in
           (select id from platform.community where slug = $1)""",
      "delete from platform.community where slug = $1"]:
    discard database.execUpdate(statement, @[textParam(slug)])

proc addSession(date: string) =
  ## One locked, approved session with one played game over the four players:
  ## the smallest source the board reads.
  let sessionId = database.queryOne(
    """insert into session.sessions
         (community_id, title, session_date, status, source, approved_at)
       values ($1::uuid, 'Snapshot session', $2::date, 'locked', 'generator',
               now())
       returning id""",
    @[textParam(communityId), textParam(date)]).get.get("id")
  discard database.execUpdate(
    """insert into rating.events (community_id, local_date, event_type, source_id)
       values ($1::uuid, $2::date, 'session', $3::uuid)""",
    @[textParam(communityId), textParam(date), textParam(sessionId)])
  for player in players:
    discard database.execUpdate(
      """insert into session.participants (community_id, session_id, player_id)
         values ($1::uuid, $2::uuid, $3::uuid)""",
      @[textParam(communityId), textParam(sessionId), textParam(player)])
  discard database.execUpdate(
    """insert into session.games
         (community_id, session_id, round_no, court_no, score_a, score_b,
          status, side_a1, side_a2, side_b1, side_b2)
       values ($1::uuid, $2::uuid, 0, 0, 30, 20, 'played', $3::uuid, $4::uuid,
               $5::uuid, $6::uuid)""",
    @[textParam(communityId), textParam(sessionId), textParam(players[0]),
      textParam(players[1]), textParam(players[2]), textParam(players[3])])
  discard database.execUpdate(
    """insert into session.game_sets
         (community_id, session_id, round_no, court_no, set_no, score_a, score_b)
       values ($1::uuid, $2::uuid, 0, 0, 1, 30, 20)""",
    @[textParam(communityId), textParam(sessionId)])

proc boardFor(day: string): seq[BoardRow] =
  ## The board read `main` performs, with the same config snapshot and params.
  let snapshot = loadSnapshot(database)
  let limit = snapshot.values[$keyRankBoardLimit].getInt()
  board(database, BoardQuery(communityId: communityId, asOf: day,
    params: loadRatingParams(snapshot, newJObject()), limit: limit, tier: ""))

proc snapshotCount(): string =
  database.queryOne(
    """select count(*)::int as n from rating.snapshots
       where community_id = $1::uuid""",
    @[textParam(communityId)]).get.get("n")

suite "ranksnapshot day selection":
  setup:
    let dsn = getEnv("MAJADU_PG_DSN")
    if dsn.len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    database = openDb(dsn, 1)
    cleanup()
    communityId = database.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ($1, 'Snapshot Test', $2) returning id""",
      @[textParam(slug), textParam(timezone)]).get.get("id")
    players.setLen(0)
    for index in 0 ..< 4:
      players.add database.queryOne(
        """insert into player.players (community_id, canonical_name, gender, tier)
           values ($1::uuid, $2, 'M', 'C') returning id""",
        @[textParam(communityId),
          textParam("Snapshot " & $index)]).get.get("id")

  teardown:
    cleanup()
    database.close()

  test "no as-of and no events takes the community's calendar date":
    let day = snapshotDay(database, "", communityId, timezone)
    # Same expression as `communityToday`, so a day taken from UTC instead of
    # the zone's calendar would drift from it.
    check day == communityToday(database, timezone)
    # Kiritimati is UTC+14 and Etc/GMT+12 is UTC-12, so the two zones can never
    # share a date: a day computed in UTC would make them equal.
    let east = snapshotDay(database, "", communityId, "Pacific/Kiritimati")
    let west = snapshotDay(database, "", communityId, "Etc/GMT+12")
    check east != west

  test "with events the latest event date anchors the day":
    addSession("2026-10-20")
    addSession("2026-10-25")
    let day = snapshotDay(database, "", communityId, timezone)
    check day == "2026-10-25"
    # The point of the branch: the day is not the day the tool ran.
    check day != communityToday(database, timezone)

  test "an explicit as-of wins over the latest event date":
    addSession("2026-10-20")
    addSession("2026-10-25")
    let day = snapshotDay(database, "2026-11-01", communityId, timezone)
    check day == "2026-11-01"

  test "every written snapshot row carries the chosen day":
    addSession("2026-10-20")
    let day = snapshotDay(database, "2026-11-01", communityId, timezone)
    let written = writeSnapshot(database, communityId, day, boardFor(day))
    check written == 4
    let row = database.queryOne(
      """select count(*)::int as n, min(taken_on)::text as first_day,
                max(taken_on)::text as last_day
         from rating.snapshots where community_id = $1::uuid""",
      @[textParam(communityId)]).get
    check row.get("n") == "4"
    check row.get("first_day") == "2026-11-01"
    check row.get("last_day") == "2026-11-01"

  test "a second run on the same day overwrites instead of duplicating":
    addSession("2026-10-20")
    let day = snapshotDay(database, "", communityId, timezone)
    let rows = boardFor(day)
    check rows.len == 4
    discard writeSnapshot(database, communityId, day, rows)
    # The second run carries a different value for one row, so "overwrites" is
    # observable: a write that skipped the conflict would leave the first value.
    var changed = rows
    changed[0].points += 7
    discard writeSnapshot(database, communityId, day, changed)
    check snapshotCount() == "4"
    let stored = database.queryOne(
      """select rating::text as rating from rating.snapshots
         where community_id = $1::uuid and player_id = $2::uuid
           and taken_on = $3::date""",
      @[textParam(communityId), textParam(changed[0].playerId),
        textParam(day)]).get
    check stored.get("rating") == $changed[0].points
    check stored.get("rating") != $rows[0].points

  test "as-of without a value and a stray argument both exit 2":
    let absent = runCli("--as-of")
    check absent.exitCode == 2
    check absent.output.contains("Usage: ranksnapshot")
    let stray = runCli("2026-11-01")
    check stray.exitCode == 2
    check stray.output.contains("Usage: ranksnapshot")