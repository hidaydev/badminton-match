## The real `db/migrations` and `db/seeds` applied to an empty database.
##
## The other suite in this directory runs the fixture directory, so nothing else
## proves the shipped SQL reaches the schema `/readyz` demands. This suite owns
## its own database because "from nothing" is the claim: a schema inside the
## application database already holds the tables the migrations create.
##
## The scratch database is named after the process, so two runs of `./task test`
## never share one, and it is dropped even when a case fails.

import std/[algorithm, options, os, sets, strutils, tables, unittest]
import db/db
import platform/config/store
import ../../main

const
  migrationsDir = "db/migrations"
  seedsDir = "db/seeds"
  appSource = "apps/api/src/app.nim"

proc databaseDsn(dsn, database: string): string =
  ## Same credentials and host, another database. PostgreSQL cannot run
  ## `create database` from inside the database that is being created.
  let query = dsn.find('?')
  let head = if query >= 0: dsn[0 ..< query] else: dsn
  let tail = if query >= 0: dsn[query .. ^1] else: ""
  let slash = head.rfind('/')
  if slash <= head.find("://") + 2:
    raise newException(ValueError, "MAJADU_PG_DSN has no database path: " & dsn)
  head[0 ..< slash] & "/" & database & tail

proc adminDsn(): string =
  ## `MAJADU_PG_ADMIN_DSN` is the maintenance connection CI exports. A local
  ## cluster where the test role already owns it needs no second variable, so
  ## the same credentials are used against `postgres` instead.
  let explicit = getEnv("MAJADU_PG_ADMIN_DSN")
  if explicit.len > 0:
    return explicit
  databaseDsn(getEnv("MAJADU_PG_DSN"), "postgres")

proc checkedName(name: string): string =
  for character in name:
    if character notin {'a' .. 'z', '0' .. '9', '_'}:
      raise newException(ValueError, "unsafe database name: " & name)
  name

proc sqlFiles(dir: string): seq[string] =
  ## The file names on disk, sorted the way `migrate` and `seed` sort them.
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".sql"):
      result.add(path.extractFilename)
  result.sort()

proc requiredRelations(): seq[string] =
  ## `/readyz` refuses a database missing any of these. The list lives in
  ## `app.nim` as a private const, so it is read from the source rather than
  ## copied here: a relation added there must be created by a migration, or this
  ## suite fails.
  let source = readFile(appSource)
  let start = source.find("const requiredRelations = [")
  if start < 0:
    raise newException(ValueError, "requiredRelations not found in " & appSource)
  let region = source[start .. ^1]
  let stop = region.find(']')
  if stop < 0:
    raise newException(ValueError, "requiredRelations has no closing bracket")
  for raw in region[0 ..< stop].splitLines():
    let line = raw.strip()
    # The comment above the list quotes `/readyz`; only the names on the list
    # lines are relations.
    if line.len == 0 or line.startsWith("#"):
      continue
    # A split on the quote leaves the relation names at the odd positions, so
    # the `const` line itself and the comment lines above contribute nothing.
    let parts = line.split("\"")
    for index in 1 ..< parts.len:
      if index mod 2 == 1:
        result.add(parts[index])

var
  admin: Db
  scratch: Db
  scratchName: string

proc bootstrap() =
  if getEnv("MAJADU_PG_DSN").len == 0:
    raise newException(ValueError,
      "MAJADU_PG_DSN is not set: run ./task dev-db and export " &
      "MAJADU_PG_DSN=postgresql://$USER@127.0.0.1:5432/bm2_test")
  scratchName = checkedName("bm2_mig_" & $getCurrentProcessId())
  try:
    admin = openDb(adminDsn(), 1)
  except DbError as error:
    raise newException(ValueError,
      "cannot connect to the maintenance database: " & error.msg &
      "; export MAJADU_PG_ADMIN_DSN (postgresql://<admin>@host:port/postgres)")
  # A crashed earlier run can leave the row behind; the name carries this
  # process id, so the drop cannot reach another run's database.
  discard admin.execUpdate("drop database if exists " & scratchName &
    " with (force)")
  discard admin.execUpdate("create database " & scratchName)
  scratch = openDb(databaseDsn(getEnv("MAJADU_PG_DSN"), scratchName), 1)

proc shutdown() =
  if scratch != nil:
    scratch.close()
    scratch = nil
  if admin != nil:
    discard admin.execUpdate("drop database if exists " & scratchName &
      " with (force)")
    admin.close()
    admin = nil

bootstrap()
try:
  suite "dbtools migrations from an empty database":
    test "every shipped migration applies in order and verify is clean":
      let files = sqlFiles(migrationsDir)
      check files.len > 0
      # No ledger exists yet, so every file is pending: the from-nothing state,
      # not a re-check of an already migrated schema.
      let pending = verifyProblems(scratch, migrationsDir)
      check pending.len == files.len
      check pending[0] == "pending migration: " & files[0].changeFileExt("")
      migrate(scratch, migrationsDir)
      check verifyProblems(scratch, migrationsDir).len == 0
      var applied: seq[string] = @[]
      for row in scratch.query(
        "select version from dbtools.schema_migrations order by version"):
        applied.add(row.get("version"))
      var expected: seq[string] = @[]
      for name in files:
        expected.add(name.changeFileExt(""))
      check applied == expected
      check "0034_etl_grants" in applied

    test "bm2_etl can run the cutover import and still cannot change the schema":
      migrate(scratch, migrationsDir)
      proc allowed(table, privilege: string): bool =
        scratch.queryOne(
          "select has_table_privilege('bm2_etl', $1, $2) as ok",
          @[textParam(table), textParam(privilege)]).get.getBool("ok")
      proc schemaUsage(schema, privilege: string): bool =
        scratch.queryOne(
          "select has_schema_privilege('bm2_etl', $1, $2) as ok",
          @[textParam(schema), textParam(privilege)]).get.getBool("ok")

      # USAGE is the privilege whose absence produced "permission denied for
      # schema"; CREATE must stay out of reach so the loader cannot add objects.
      for schema in ["platform", "player", "session", "community", "rating",
                     "tournament", "achievement", "import"]:
        check schemaUsage(schema, "USAGE")
        check not schemaUsage(schema, "CREATE")

      # Read and written in the same pass (upserts read their own rows too).
      let upserted = @["player.players", "session.sessions", "session.courts",
        "session.participants", "session.games", "tournament.tournaments",
        "tournament.pairs", "tournament.groups", "tournament.matches",
        "tournament.teams", "tournament.team_players",
        "tournament.team_matches", "tournament.team_partai",
        "rating.sources", "rating.levels", "rating.snapshots",
        "rating.events", "rating.player_state", "import.row_map"]
      # Inserted only: the loader never updates these rows.
      let inserted = @["platform.community", "player.aliases",
        "session.game_sets", "session.game_skips", "achievement.earned"]
      # Reference rows the loader reads but never writes.
      let reference = @["platform.config", "platform.config_version",
        "platform.cutover_state", "community.settings",
        "achievement.definitions", "session.game_results"]
      # The loader clears and rewrites these itself (game sets and skips per
      # game, the rating tables on every rebuild, stale badges on backfill).
      let rewritten = @["session.game_sets", "session.game_skips",
        "rating.events", "rating.player_state", "achievement.earned"]

      for table in upserted:
        check allowed(table, "SELECT")
        check allowed(table, "INSERT")
        check allowed(table, "UPDATE")
      for table in inserted:
        check allowed(table, "SELECT")
        check allowed(table, "INSERT")
        check not allowed(table, "UPDATE")
      for table in reference:
        check allowed(table, "SELECT")
        check not allowed(table, "INSERT")
        check not allowed(table, "UPDATE")
      for table in upserted & inserted & reference:
        # No TRUNCATE anywhere, and DELETE only on the tables listed above.
        check not allowed(table, "TRUNCATE")
        check allowed(table, "DELETE") == (table in rewritten)

    test "every relation /readyz requires exists after the migrations":
      migrate(scratch, migrationsDir)
      let wanted = requiredRelations()
      check wanted.len > 0
      check "platform.config" in wanted
      var missing: seq[string] = @[]
      for relation in wanted:
        let parts = relation.split('.')
        let found = scratch.queryOne(
          """select 1 as ok
               from pg_class c
               join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = $1 and c.relname = $2""",
          @[textParam(parts[0]), textParam(parts[1])])
        if found.isNone:
          missing.add(relation)
      checkpoint("missing relations: " & missing.join(", "))
      check missing.len == 0

    test "a second migrate writes no ledger row and no new checksum":
      const ledgerRows = "select version, checksum, applied_at " &
        "from dbtools.schema_migrations order by version"
      migrate(scratch, migrationsDir)
      let before = scratch.query(ledgerRows)
      migrate(scratch, migrationsDir)
      let after = scratch.query(ledgerRows)
      check before.len == after.len
      check before.len > 0
      for index in 0 ..< before.len:
        check before[index].get("version") == after[index].get("version")
        check before[index].get("checksum") == after[index].get("checksum")
        # The timestamp moves only when a row is written again.
        check before[index].get("applied_at") == after[index].get("applied_at")

    test "seed runs twice and the platform snapshot loads from the registry":
      migrate(scratch, migrationsDir)
      seed(scratch, seedsDir)
      seed(scratch, seedsDir)
      let ledger = scratch.queryOne(
        "select count(*) as total from dbtools.seed_files").get
      check ledger.getInt("total") == sqlFiles(seedsDir).len
      # The badge catalog is the other seed file, and nothing reads it through
      # `loadSnapshot`, so its rows are counted here.
      let definitions = scratch.queryOne(
        "select count(*) as total from achievement.definitions").get
      check definitions.getInt("total") > 0
      let snapshot = loadSnapshot(scratch)
      check snapshot.version > 0
      # Exactly the registry keys: an extra row is a key no code reads, and a
      # missing one would have made `loadSnapshot` raise instead.
      check snapshot.values.len == allKeys.len
      var registry = initHashSet[string]()
      for entry in allKeys:
        registry.incl $entry.key
      for key in snapshot.values.keys:
        check key in registry

    test "no shipped migration declares the contract marker":
      # `deploy-vps.sh` never passes `--allow-contract`, so a pending marker in
      # the shipped directory would stop every deploy. An applied one is fine
      # (its ledger row records the flag), and the from-empty run below proves
      # the shipped set has no pending contract file.
      check contractRefusal(migrationsDir, false).len == 0
      migrate(scratch, migrationsDir)
      let shipped = sqlFiles(migrationsDir)
      let last = scratch.queryOne(
        "select version from dbtools.schema_migrations order by version desc limit 1").get
      check last.get("version") == shipped[^1].changeFileExt("")

    test "a scoring rule without its two numbers is rejected at write time":
      migrate(scratch, migrationsDir)
      let communityId = scratch.queryOne(
        """insert into platform.community (slug, name, timezone)
           values ('rules-shape', 'Rules Shape', 'Asia/Jakarta') returning id""")
        .get.get("id")
      expect DbError:
        discard scratch.execUpdate(
          """insert into session.sessions
               (community_id, session_date, status, source, scoring_rules)
             values ($1::uuid, '2026-11-01', 'draft', 'manual',
                     '{"gamesToWin":"two","pointsToWin":21}'::jsonb)""",
          @[textParam(communityId)])
      expect DbError:
        discard scratch.execUpdate(
          """insert into session.sessions
               (community_id, session_date, status, source, scoring_rules)
             values ($1::uuid, '2026-11-01', 'draft', 'manual',
                     '{"gamesToWin":1}'::jsonb)""",
          @[textParam(communityId)])

      # A valid legacy preset still reads every game of its session.
      let sessionId = scratch.queryOne(
        """insert into session.sessions
             (community_id, session_date, status, source, scoring_rules)
           values ($1::uuid, '2026-11-01', 'draft', 'manual',
                   '{"id":"legacy_v1","gamesToWin":1,"pointsToWin":30,
                     "winBy":1,"deuceAt":null,"maxPoints":99}'::jsonb)
           returning id""",
        @[textParam(communityId)]).get.get("id")
      discard scratch.execUpdate(
        """insert into session.games
             (community_id, session_id, round_no, court_no, status)
           values ($1::uuid, $2::uuid, 0, 0, 'scheduled')""",
        @[textParam(communityId), textParam(sessionId)])
      discard scratch.execUpdate(
        """insert into session.game_sets
             (community_id, session_id, round_no, court_no, set_no, score_a, score_b)
           values ($1::uuid, $2::uuid, 0, 0, 1, 30, 21)""",
        @[textParam(communityId), textParam(sessionId)])
      let results = scratch.queryOne(
        """select count(*)::int as total, min(games_to_win)::text as games_to_win
           from session.game_results where community_id = $1::uuid and session_id = $2::uuid""",
        @[textParam(communityId), textParam(sessionId)]).get
      check results.get("total") == "1"
      check results.get("games_to_win") == "1"
finally:
  shutdown()