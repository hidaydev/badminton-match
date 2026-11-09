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
      # `deploy-vps.sh` never passes `--allow-contract`, so a marker in the
      # shipped directory would stop every deploy.
      check contractRefusal(migrationsDir, false).len == 0
      migrate(scratch, migrationsDir)
      let last = scratch.queryOne(
        "select version from dbtools.schema_migrations order by version desc limit 1").get
      check last.get("version") == "0036_oauth_flow_key_id"

    test "the last migration applies to a populated schema from the previous version":
      # QA-16: every other case here starts from nothing. The upgrade path the
      # next release has to take is a migration over live rows, and it is where a
      # rewrite or a dropped column without a backfill shows up. This builds the
      # schema at N-1, inserts a row per core table, then applies N and proves
      # the rows and the pre-existing columns survived.
      let files = sqlFiles(migrationsDir)
      check files.len > 1
      let last = files[^1]
      let upgradeName = checkedName("bm2_mig_up_" & $getCurrentProcessId())
      let staging = getTempDir() / ("majadu-upgrade-" & $getCurrentProcessId())
      removeDir(staging)
      createDir(staging)
      for index in 0 ..< files.len - 1:
        copyFile(migrationsDir / files[index], staging / files[index])

      discard admin.execUpdate("drop database if exists " & upgradeName &
        " with (force)")
      discard admin.execUpdate("create database " & upgradeName)
      let up = openDb(databaseDsn(getEnv("MAJADU_PG_DSN"), upgradeName), 1)
      try:
        migrate(up, staging)
        const
          communityId = "11111111-1111-4111-8111-111111111111"
          userId = "22222222-2222-4222-8222-222222222222"
          sessionId = "33333333-3333-4333-8333-333333333333"
        discard up.execUpdate(
          """insert into platform.community (id, slug, name, timezone)
             values ($1::uuid, 'upgrade-probe', 'Upgrade Probe', 'UTC')""",
          @[textParam(communityId)])
        discard up.execUpdate(
          """insert into platform.user (id, google_sub, email_hash, display_name)
             values ($1::uuid, 'upgrade-probe', 'upgrade@example.invalid',
                     'Upgrade Probe')""",
          @[textParam(userId)])
        discard up.execUpdate(
          """insert into community.membership (community_id, user_id, role)
             values ($1::uuid, $2::uuid, 'member')""",
          @[textParam(communityId), textParam(userId)])
        discard up.execUpdate(
          """insert into session.sessions
               (id, community_id, title, session_date, status, source)
             values ($1::uuid, $2::uuid, 'Upgrade Probe', '2026-01-01',
                     'draft', 'manual')""",
          @[textParam(sessionId), textParam(communityId)])

        # Every column that exists before N. A migration that drops one without a
        # backfill fails the comparison below, which is the point.
        let columns = up.query(
          """select table_schema, table_name, column_name
               from information_schema.columns
              where table_schema in ('platform', 'community', 'session',
                                     'rating', 'tournament', 'account',
                                     'share', 'auth', 'achievement')
              order by 1, 2, 3""")

        # N is not in the staging directory yet, so this applies exactly one file.
        copyFile(migrationsDir / last, staging / last)
        migrate(up, staging)

        check verifyProblems(up, staging).len == 0
        let ledger = up.queryOne(
          "select version from dbtools.schema_migrations order by version desc limit 1").get
        check ledger.get("version") == last.changeFileExt("")

        var missing: seq[string] = @[]
        for row in columns:
          let found = up.queryOne(
            """select 1 as ok from information_schema.columns
                where table_schema = $1 and table_name = $2
                  and column_name = $3""",
            @[textParam(row.get("table_schema")),
              textParam(row.get("table_name")),
              textParam(row.get("column_name"))])
          if found.isNone:
            missing.add(row.get("table_schema") & "." & row.get("table_name") &
              "." & row.get("column_name"))
        checkpoint("columns dropped without a backfill: " & missing.join(", "))
        check missing.len == 0

        if missing.len == 0:
          check up.queryOne(
            "select display_name from platform.user where id = $1::uuid",
            @[textParam(userId)]).get.get("display_name") == "Upgrade Probe"
          check up.queryOne(
            "select name from platform.community where id = $1::uuid",
            @[textParam(communityId)]).get.get("name") == "Upgrade Probe"
          check up.queryOne(
            """select title, status, source from session.sessions
                where id = $1::uuid""",
            @[textParam(sessionId)]).get.get("title") == "Upgrade Probe"
          check up.queryOne(
            """select role from community.membership
                where community_id = $1::uuid and user_id = $2::uuid""",
            @[textParam(communityId), textParam(userId)]).get.get("role") == "member"
      finally:
        up.close()
        discard admin.execUpdate("drop database if exists " & upgradeName &
          " with (force)")
        removeDir(staging)

finally:
  shutdown()