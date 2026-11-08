import std/[json, options, os, osproc, strtabs, strutils, unittest]
import db/db
import ../main

## Runs only when both databases are named, because an import needs two:
##   MAJADU_IMPORT_TEST_SOURCE_DSN  a disposable v1 database (bm.players)
##   MAJADU_IMPORT_TEST_DSN         a disposable v2 database, migrated
##
## The test writes into both, so point them at scratch databases only.

let sourceDsn = getEnv("MAJADU_IMPORT_TEST_SOURCE_DSN")
let targetDsn = getEnv("MAJADU_IMPORT_TEST_DSN")

if sourceDsn.len == 0 or targetDsn.len == 0:
  echo "SKIP import suite: MAJADU_IMPORT_TEST_SOURCE_DSN / MAJADU_IMPORT_TEST_DSN not set"
  quit(77)

const verifyProbe = "IMPORT_TEST_VERIFY"

proc probeEnv(communityId: string): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for (key, item) in envPairs():
    result[key] = item
  result[verifyProbe] = communityId

proc selfVerify(communityId: string): tuple[output: string, exitCode: int] =
  ## `verifyEtl` exits 1 on a mismatch, so each report runs in a child process
  ## that is this same binary: the exit status is the assertion, and a failure
  ## does not end the suite.
  var binary = getAppFilename()
  if not binary.isAbsolute:
    binary = getCurrentDir() / binary
  execCmdEx(quoteShell(binary), env = probeEnv(communityId))

proc reportOf(output: string): JsonNode =
  ## The report is the one JSON line `verifyEtl` echoes; problems go to stderr.
  for line in output.splitLines():
    if line.strip.startsWith("{"):
      result = parseJson(line.strip)

when isMainModule:
  # The probe branch runs before bootstrap, so a probe run never removes rows.
  let probed = getEnv(verifyProbe)
  if probed.len > 0:
    let childSource = openDb(sourceDsn, 1)
    let childTarget = openDb(targetDsn, 1)
    putEnv("MAJADU_IMPORT_COMMUNITY_ID", probed)
    verifyEtl(childSource, childTarget, "")
    quit(0)

var source: Db
var target: Db

proc bootstrap() =
  source = openDb(sourceDsn, 1)
  target = openDb(targetDsn, 1)
  # Both databases are scratch, but they are also used by hand between runs, so
  # the test removes only what it owns: rows it named and the community it made.
  discard source.execUpdate(
    "delete from bm.sessions where share_code = 'import-session-1'")
  discard source.execUpdate(
    "delete from bm.players where canonical_name = 'Import Tester'")
  discard source.execUpdate(
    "delete from bm.players where canonical_name like 'Import %'")
  let existing = target.queryOne(
    "select id::text as id from platform.community where slug = 'import-test'")
  if existing.isSome:
    let id = existing.get.get("id")
    # Every reference to a player and to a tournament is `on delete restrict`, so
    # the rows go children first and the community last.
    for statement in [
        "delete from rating.events where community_id = $1::uuid",
        "delete from rating.player_state where community_id = $1::uuid",
        "delete from rating.sources where community_id = $1::uuid",
        "delete from achievement.earned where community_id = $1::uuid",
        "delete from tournament.team_partai where community_id = $1::uuid",
        "delete from tournament.team_matches where community_id = $1::uuid",
        "delete from tournament.team_players where community_id = $1::uuid",
        "delete from tournament.teams where community_id = $1::uuid",
        "delete from tournament.groups where community_id = $1::uuid",
        "delete from tournament.matches where community_id = $1::uuid",
        "delete from tournament.pairs where community_id = $1::uuid",
        "delete from tournament.tournaments where community_id = $1::uuid",
        "delete from session.games where community_id = $1::uuid",
        "delete from session.participants where community_id = $1::uuid",
        "delete from session.courts where community_id = $1::uuid",
        "delete from session.sessions where community_id = $1::uuid",
        "delete from player.aliases where community_id = $1::uuid",
        "delete from player.players where community_id = $1::uuid",
        "delete from import.row_map where community_id = $1::uuid",
        "delete from platform.community where id = $1::uuid"]:
      discard target.execUpdate(statement, @[textParam(id)])
  # The empty-community case below makes this one; it owns none of the rows
  # above, so it goes on its own.
  let empty = target.queryOne(
    "select id::text as id from platform.community where slug = 'import-empty-test'")
  if empty.isSome:
    discard target.execUpdate(
      "delete from platform.community where id = $1::uuid",
      @[textParam(empty.get.get("id"))])

bootstrap()

suite "v1 import":
  test "players and aliases arrive once, and a rerun changes nothing":
    discard source.execUpdate(
      """insert into bm.players (canonical_name, tier, gender)
         values ('Import Tester', 'C', 'F')
         on conflict do nothing""")
    let found = source.queryOne(
      "select id::text as id from bm.players where canonical_name = 'Import Tester'")
    check found.isSome
    let playerId = found.get.get("id")
    # v1 stores aliases normalised (lowercase, single spaces); a duplicate name
    # is a conflict, anything else is a bug this test should see.
    discard source.execUpdate(
      """insert into bm.player_aliases (alias_name, player_id)
         values ('tester import', $1::uuid) on conflict do nothing""",
      @[textParam(playerId)])

    let first = importEtl(source, target, "import-test", "Import Test", "", false)
    check first.players.created >= 1
    check first.players.collapsed == 0

    let community = target.queryOne(
      "select id::text as id from platform.community where slug = 'import-test'"
      ).get.get("id")
    let afterFirst = target.queryOne(
      """select count(*)::int as n from player.players
         where community_id = $1::uuid and canonical_name = 'Import Tester'""",
      @[textParam(community)])
    check afterFirst.get.get("n") == "1"

    let second = importEtl(source, target, "import-test", "Import Test", "", false)
    check second.players.created == 0
    check second.players.updated >= 1

    let afterSecond = target.queryOne(
      """select count(*)::int as n from player.players
         where community_id = $1::uuid and canonical_name = 'Import Tester'""",
      @[textParam(community)])
    check afterSecond.get.get("n") == "1"

  test "verify finds no difference after the import":
    let found = target.queryOne(
      "select id::text as id from platform.community where slug = 'import-test'")
    check found.isSome
    let community = found.get.get("id")
    putEnv("MAJADU_IMPORT_COMMUNITY_ID", community)
    var problems = verifyPlayers(source, target, community)
    problems.add verifyAliases(source, target, community)
    delEnv("MAJADU_IMPORT_COMMUNITY_ID")
    for problem in problems:
      checkpoint problem
    check problems.len == 0

  test "a session past midnight in WIB keeps the community's calendar date":
    # A v1 timestamp is an instant. This one is 23:30 on 3 November in Jakarta,
    # which is already 4 November in UTC; taking the UTC date would move the
    # session to the next day.
    let community = target.queryOne(
      "select id::text as id, timezone from platform.community where slug = 'import-test'").get
    # 00:30 on 4 November in Jakarta is still 3 November in UTC, so a naive
    # conversion would put the session on the wrong day.
    let day = calendarDate(target, "2026-11-04 00:30:00+07",
      community.get("timezone"))
    check day == "2026-11-04"
    let utc = target.queryOne(
      "select ('2026-11-04 00:30:00+07'::timestamptz at time zone 'UTC')::date::text as day").get
    check utc.get("day") == "2026-11-03"

  test "a draft session and its game arrive once, sides included":
    discard source.execUpdate(
      "delete from bm.sessions where share_code = 'import-session-1'")
    let session = source.queryOne(
      """insert into bm.sessions
           (share_code, title, session_date, session_start, slot_minutes,
            status, source, created_at, updated_at)
         values ('import-session-1', 'Imported Night', '2026-11-03', '19:00', 30,
                 'draft', 'manual', '2026-11-04 00:30:00+07',
                 '2026-11-04 00:30:00+07')
         returning id::text as id""").get.get("id")
    var participants: seq[string] = @[]
    for index, name in ["Import One", "Import Two"]:
      discard source.execUpdate(
        """insert into bm.players (canonical_name, gender, tier)
           values ($1, 'F', 'C')""",
        @[textParam(name)])
      let player = source.queryOne(
        "select id::text as id from bm.players where canonical_name = $1",
        @[textParam(name)]).get.get("id")
      let participant = source.queryOne(
        """insert into bm.session_players
             (player_id, player_ref, source_name, sort_order, gender, tier,
              session_id)
           values ($1::uuid, $2, $3, $4, 'F', 3, $5::uuid)
           returning internal_id::text as id""",
        @[textParam(player), textParam("p" & $(index + 1)), textParam(name),
          intParam(index.int64), textParam(session)]).get.get("id")
      participants.add(participant)
    let game = source.queryOne(
      """insert into bm.scheduled_games
           (slot_index, court_index, status, source, session_id, is_played,
            score_a, score_b, skipped_player_refs)
         values (0, 0, 'played', 'manual', $1::uuid, true, 21, 18,
                 array['p1'])
         returning internal_id::text as id""",
      @[textParam(session)]).get.get("id")
    for index, participant in participants:
      discard source.execUpdate(
        """insert into bm.scheduled_game_players
             (team, position, scheduled_game_internal_id, session_player_internal_id)
           values ($1, $2, $3::uuid, $4::uuid)""",
        @[textParam(if index == 0: "A" else: "B"), intParam(0),
          textParam(game), textParam(participant)])

    let first = importEtl(source, target, "import-test", "Import Test", "", false)
    check first.sessions.created == 1
    check first.games.created == 1

    let communityId = target.queryOne(
      "select id::text as id from platform.community where slug = 'import-test'"
      ).get.get("id")
    let imported = target.queryOne(
      """select s.title, s.session_date::text as session_date,
                s.approved_at is not null as approved,
                g.round_no, g.court_no, g.score_a, g.score_b, g.status,
                a.canonical_name as side_a, b.canonical_name as side_b
         from session.sessions s
         join session.games g on g.session_id = s.id
         left join player.players a on a.id = g.side_a1
         left join player.players b on b.id = g.side_b1
         where s.community_id = $1::uuid and s.title = 'Imported Night'""",
      @[textParam(communityId)]).get
    check imported.get("session_date") == "2026-11-03"
    # A draft was never approved in v1, and the import must not invent approval:
    # an approved draft would enter the rating rebuild.
    check imported.get("approved") == "f"
    check imported.get("status") == "played"
    check imported.get("score_a") == "21"
    check imported.get("side_a") == "Import One"
    check imported.get("side_b") == "Import Two"

    let skipped = target.queryOne(
      """select p.canonical_name as name
         from session.game_skips gs
         join player.players p on p.id = gs.player_id
         where gs.community_id = $1::uuid
           and gs.session_id = (select id from session.sessions
             where community_id = $1::uuid and title = 'Imported Night')""",
      @[textParam(communityId)])
    check skipped.isSome
    check skipped.get.get("name") == "Import One"

    let second = importEtl(source, target, "import-test", "Import Test", "", false)
    check second.sessions.created == 0
    check second.games.created == 0

    var problems = verifySessions(source, target, communityId)
    problems.add verifyGames(source, target, communityId)
    for problem in problems:
      checkpoint problem
    check problems.len == 0

  test "the published session feeds the ledger and keeps its sign-off":
    let community = target.queryOne(
      "select id::text as id from platform.community where slug = 'import-test'"
      ).get.get("id")
    # The fixture's v1 session was published and finalized; the draft above must
    # not add a second event.
    let events = target.queryOne(
      """select count(*)::int as n from rating.events
         where community_id = $1::uuid""", @[textParam(community)]).get
    check events.get("n") == "1"
    let state = target.queryOne(
      """select count(*)::int as n from rating.player_state
         where community_id = $1::uuid""", @[textParam(community)]).get
    check parseInt(state.get("n")) > 0
    let sources = target.queryOne(
      """select count(*)::int as n from rating.sources
         where community_id = $1::uuid and finalized""",
      @[textParam(community)]).get
    check sources.get("n") == "1"

    var problems = verifyRating(source, target, community)
    for problem in problems:
      checkpoint problem
    check problems.len == 0

  test "a classic and a team tournament arrive with their children":
    let community = target.queryOne(
      "select id::text as id from platform.community where slug = 'import-test'"
      ).get.get("id")
    let classic = target.queryOne(
      """select t.id::text as id, t.format, t.status,
                count(m.id)::int as matches
         from tournament.tournaments t
         left join tournament.matches m on m.tournament_id = t.id
         where t.community_id = $1::uuid and t.format = 'classic'
         group by t.id, t.format, t.status""", @[textParam(community)]).get
    check classic.get("matches") == "10"
    # Every match in the v1 fixture is scored, so the derived status is done.
    check classic.get("status") == "completed"
    let final = target.queryOne(
      """select m.round_no, m.pic_name, p.display_name
         from tournament.matches m
         join tournament.pairs p on p.id = m.pair_a_id
         where m.community_id = $1::uuid and m.match_key = 'F-1'""",
      @[textParam(community)]).get
    check final.get("round_no") == "4"
    check final.get("pic_name").len > 0
    check final.get("display_name").len > 0

    let team = target.queryOne(
      """select t.id::text as id from tournament.tournaments t
         where t.community_id = $1::uuid and t.format = 'team'""",
      @[textParam(community)]).get
    let teams = target.queryOne(
      """select count(*)::int as n from tournament.teams
         where community_id = $1::uuid and tournament_id = $2::uuid""",
      @[textParam(community), textParam(team.get("id"))]).get
    check teams.get("n") == "4"
    let roster = target.queryOne(
      """select count(*)::int as n from tournament.team_players p
         join tournament.teams t on t.id = p.team_id
         where t.community_id = $1::uuid and t.tournament_id = $2::uuid""",
      @[textParam(community), textParam(team.get("id"))]).get
    check roster.get("n") == "16"
    let partai = target.queryOne(
      """select count(*)::int as n from tournament.team_partai p
         join tournament.team_matches m on m.id = p.team_match_id
         where m.community_id = $1::uuid and m.tournament_id = $2::uuid""",
      @[textParam(community), textParam(team.get("id"))]).get
    check partai.get("n") == "9"

    var problems = verifyTournaments(source, target, community)
    for problem in problems:
      checkpoint problem
    check problems.len == 0

  test "v1 group slots stored 1-based become 0..3":
    let community = target.queryOne(
      "select id::text as id from platform.community where slug = 'import-test'"
      ).get.get("id")
    let oldId = source.queryOne(
      """select id::text as id from bm.tournaments
         where format = 'classic' order by id limit 1""").get.get("id")
    # Production v1 rows use 1..4 while the synthetic fixture uses 0-based
    # slots; a real import failed on that before the mapping normalised it.
    # Two steps: a single +1 hits the unique (tournament, group, position) row
    # that already occupies the next slot.
    discard source.execUpdate(
      """update bm.tournament_groups set position = position + 100
         where tournament_id = $1::uuid""", @[textParam(oldId)])
    discard source.execUpdate(
      """update bm.tournament_groups set position = position - 99
         where tournament_id = $1::uuid""", @[textParam(oldId)])
    discard importEtl(source, target, "import-test", "Import Test", "", false)
    let newId = target.queryOne(
      """select new_id::text as id from import.row_map
         where community_id = $1::uuid and entity = 'tournament'
           and old_id = $2""",
      @[textParam(community), textParam(oldId)]).get.get("id")
    let slots = target.queryOne(
      """select count(*)::int as n, min(position)::int as lo,
                max(position)::int as hi
         from tournament.groups
         where community_id = $1::uuid and tournament_id = $2::uuid""",
      @[textParam(community), textParam(newId)]).get
    check slots.get("n") == "6"
    check slots.get("lo") == "0"
    check parseInt(slots.get("hi")) <= 3

  test "a v1 statistic becomes the thresholds it has passed":
    let community = target.queryOne(
      "select id::text as id from platform.community where slug = 'import-test'"
      ).get.get("id")
    # v1 stored `medal:games` with value 57; v2 stores one row per threshold.
    let player = target.queryOne(
      """select new_id::text as id from import.row_map
         where community_id = $1::uuid and entity = 'player'
           and old_id = 'ec779c36-93f8-4501-bed9-eeb4936de39d'""",
      @[textParam(community)])
    check player.isSome
    let keys = target.query(
      """select achievement_key, earned_at::date::text as day
         from achievement.earned
         where community_id = $1::uuid and player_id = $2::uuid
           and achievement_key like 'games:%'
         order by achievement_key""",
      @[textParam(community), textParam(player.get.get("id"))])
    var found: seq[string] = @[]
    for row in keys:
      found.add(row.get("achievement_key"))
      # The v1 date survives the backfill, which uses do nothing.
      check row.get("day") == "2026-10-11"
    check found == @["games:10", "games:25", "games:50"]

    # A value below the first threshold writes nothing but is not an error.
    let low = target.queryOne(
      """select count(*)::int as n from achievement.earned
         where community_id = $1::uuid and achievement_key like 'wins:%'
           and player_id in (select new_id from import.row_map
                             where community_id = $1::uuid
                               and old_id = '721511bb-fb1a-401f-96d9-005a18b777c1')""",
      @[textParam(community)]).get
    check low.get("n") == "0"

    var problems = verifyAchievements(source, target, community)
    for problem in problems:
      checkpoint problem
    check problems.len == 0

  test "verify reports no problem across the eight checked domains":
    let community = target.queryOne(
      "select id::text as id from platform.community where slug = 'import-test'"
      ).get.get("id")
    let run = selfVerify(community)
    for line in run.output.splitLines():
      checkpoint line
    check run.exitCode == 0
    let report = reportOf(run.output)
    check report["communityId"].getStr == community
    check report["problems"].getInt == 0
    # A report that silently checked fewer domains would read the same as a
    # clean one, so the list is part of the contract.
    check report["checkedDomains"].getElems().len == 8

  test "verify refuses an empty community instead of reporting it clean":
    # An import that read nothing leaves all eight domains empty. Reporting
    # zero problems there would hide the missing import, so verify names the
    # missing players and exits 1.
    let empty = target.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ('import-empty-test', 'Import Empty', 'Asia/Jakarta')
         returning id::text as id""").get.get("id")
    let run = selfVerify(empty)
    discard target.execUpdate(
      "delete from platform.community where id = $1::uuid", @[textParam(empty)])
    for line in run.output.splitLines():
      checkpoint line
    check run.exitCode == 1
    check run.output.contains("no player has been imported into this community")
