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
  discard target.execUpdate(
    "delete from platform.community where slug = 'import-test'") # cascades the row map

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

    let afterFirst = target.queryOne(
      "select count(*)::int as n from player.players where canonical_name = 'Import Tester'")
    check afterFirst.get.get("n") == "1"

    let second = importEtl(source, target, "import-test", "Import Test", "", false)
    check second.players.created == 0
    check second.players.updated >= 1

    let afterSecond = target.queryOne(
      "select count(*)::int as n from player.players where canonical_name = 'Import Tester'")
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
