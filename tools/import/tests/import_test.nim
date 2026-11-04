import std/[options, os, strutils, unittest]
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
  echo "import suite: skipped (MAJADU_IMPORT_TEST_SOURCE_DSN / MAJADU_IMPORT_TEST_DSN not set)"
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
    # Players reference the community with `on delete restrict`, so the rows go
    # first and the community last.
    discard target.execUpdate(
      "delete from import.row_map where community_id = $1::uuid", @[textParam(id)])
    discard target.execUpdate(
      "delete from session.games where community_id = $1::uuid", @[textParam(id)])
    discard target.execUpdate(
      "delete from session.participants where community_id = $1::uuid",
      @[textParam(id)])
    discard target.execUpdate(
      "delete from session.courts where community_id = $1::uuid", @[textParam(id)])
    discard target.execUpdate(
      "delete from session.sessions where community_id = $1::uuid", @[textParam(id)])
    discard target.execUpdate(
      "delete from player.aliases where community_id = $1::uuid", @[textParam(id)])
    discard target.execUpdate(
      "delete from player.players where community_id = $1::uuid", @[textParam(id)])
    discard target.execUpdate(
      "delete from platform.community where id = $1::uuid", @[textParam(id)])

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
            score_a, score_b)
         values (0, 0, 'played', 'manual', $1::uuid, true, 21, 18)
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
