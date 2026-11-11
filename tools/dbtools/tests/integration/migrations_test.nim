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

    test "a registry key whose seed row is missing is repaired by the deploy's seed":
      # DB-06: the deploy runs `migrate`, then `seed`, then starts the service.
      # A new registry key arrives as a row in the seed file, and the boot path
      # reads only the rows. Take one row away and forget the file's ledger row,
      # which is the state a changed seed file is in, then prove the boot refuses
      # and that the deploy's own step repairs it without manual SQL.
      migrate(scratch, migrationsDir)
      seed(scratch, seedsDir)
      let configKey = $allKeys[0].key
      discard scratch.execUpdate(
        "delete from platform.config where key = $1", @[textParam(configKey)])
      discard scratch.execUpdate(
        "delete from dbtools.seed_files where name = 'platform_config.sql'")
      var refused = false
      try:
        discard loadSnapshot(scratch)
      except ConfigError:
        refused = true
      check refused
      seed(scratch, seedsDir)
      let repaired = loadSnapshot(scratch)
      check repaired.values.len == allKeys.len
      check repaired.values.hasKey(configKey)

    test "a game on a court the session does not have is refused":
      # DB-11: the foreign key itself is deferred by ADR-017, because a v2
      # session has no court rows. Where a court register exists, the coordinate
      # is enforced, and a court still used by a game cannot be removed.
      migrate(scratch, migrationsDir)
      let communityId = scratch.queryOne(
        """insert into platform.community (slug, name, timezone)
           values ('court-guard', 'Court Guard', 'Asia/Jakarta') returning id""")
        .get.get("id")
      let bareSession = scratch.queryOne(
        """insert into session.sessions
             (community_id, session_date, status, source)
           values ($1::uuid, '2026-11-03', 'draft', 'manual') returning id""",
        @[textParam(communityId)]).get.get("id")
      # No court rows: the schedule writer's own shape stays accepted.
      discard scratch.execUpdate(
        """insert into session.games
             (community_id, session_id, round_no, court_no, status)
           values ($1::uuid, $2::uuid, 0, 99, 'scheduled')""",
        @[textParam(communityId), textParam(bareSession)])

      let registeredSession = scratch.queryOne(
        """insert into session.sessions
             (community_id, session_date, status, source)
           values ($1::uuid, '2026-11-03', 'draft', 'manual') returning id""",
        @[textParam(communityId)]).get.get("id")
      discard scratch.execUpdate(
        """insert into session.courts
             (community_id, session_id, court_index, court_name, start_time,
              end_time, declared)
           values ($1::uuid, $2::uuid, 0, 'Court 1', '08:00', '09:00', true)""",
        @[textParam(communityId), textParam(registeredSession)])
      var state = ""
      try:
        discard scratch.execUpdate(
          """insert into session.games
               (community_id, session_id, round_no, court_no, status)
             values ($1::uuid, $2::uuid, 0, 99, 'scheduled')""",
          @[textParam(communityId), textParam(registeredSession)])
      except DbError as error:
        state = error.sqlState
      check state == "23503"

      discard scratch.execUpdate(
        """insert into session.games
             (community_id, session_id, round_no, court_no, status)
           values ($1::uuid, $2::uuid, 0, 0, 'scheduled')""",
        @[textParam(communityId), textParam(registeredSession)])
      state = ""
      try:
        discard scratch.execUpdate(
          """delete from session.courts
              where community_id = $1::uuid and session_id = $2::uuid
                and court_index = 0""",
          @[textParam(communityId), textParam(registeredSession)])
      except DbError as error:
        state = error.sqlState
      check state == "23503"

    test "the court keys are deferred and name the register":
      # DB-11: ADR-017 deferred `games_court_fk` and `game_skips_court_fk`
      # because no writer created a court row. 0056 materialises the row, so the
      # keys are real, and they are deferred because a session delete removes
      # its courts and its games in one statement.
      migrate(scratch, migrationsDir)
      for name in ["games_court_fk", "game_skips_court_fk"]:
        let row = scratch.queryOne(
          """select condeferrable::text as deferrable,
                    condeferred::text as initially_deferred,
                    confrelid::regclass::text as target
               from pg_constraint where conname = $1""", @[textParam(name)])
        check row.isSome
        check row.get.get("deferrable") == "true"
        check row.get.get("initially_deferred") == "true"
        check row.get.get("target") == "session.courts"

    test "the court backfill leaves no game or skip without its court":
      # The upgrade path: a database at 0055 has games and skips and no court
      # rows, which is every v2 session. 0056 has to give each coordinate a row
      # before the key exists, or the migration fails on its own data.
      const courtMigration = "0056_court_foreign_keys.sql"
      let courtName = checkedName("bm2_mig_court_" & $getCurrentProcessId())
      let staging = getTempDir() / ("majadu-court-" & $getCurrentProcessId())
      removeDir(staging)
      createDir(staging)
      for name in sqlFiles(migrationsDir):
        if name < courtMigration:
          copyFile(migrationsDir / name, staging / name)

      discard admin.execUpdate("drop database if exists " & courtName &
        " with (force)")
      discard admin.execUpdate("create database " & courtName)
      let up = openDb(databaseDsn(getEnv("MAJADU_PG_DSN"), courtName), 1)
      try:
        migrate(up, staging)
        const
          communityId = "44444444-4444-4444-8444-444444444444"
          sessionId = "55555555-5555-4555-8555-555555555555"
          playerId = "66666666-6666-4666-8666-666666666666"
        discard up.execUpdate(
          """insert into platform.community (id, slug, name, timezone)
             values ($1::uuid, 'court-backfill', 'Court Backfill', 'UTC')""",
          @[textParam(communityId)])
        discard up.execUpdate(
          """insert into session.sessions
               (id, community_id, session_date, start_time, slot_minutes,
                status, source)
             values ($1::uuid, $2::uuid, '2026-11-06', '18:00', 30, 'draft',
                     'manual')""",
          @[textParam(sessionId), textParam(communityId)])
        discard up.execUpdate(
          """insert into player.players (id, community_id, canonical_name, gender)
             values ($1::uuid, $2::uuid, 'Court Probe', 'M')""",
          @[textParam(playerId), textParam(communityId)])
        for round in 0 .. 1:
          discard up.execUpdate(
            """insert into session.games
                 (community_id, session_id, round_no, court_no, status)
               values ($1::uuid, $2::uuid, $3::int, $4::int, 'scheduled')""",
            @[textParam(communityId), textParam(sessionId),
              intParam(round.int64), intParam((round * 3).int64)])
        discard up.execUpdate(
          """insert into session.game_skips
               (community_id, session_id, round_no, court_no, player_id)
             values ($1::uuid, $2::uuid, 0, 0, $3::uuid)""",
          @[textParam(communityId), textParam(sessionId), textParam(playerId)])

        # 0055 is the head of what the staging directory holds; one more file.
        copyFile(migrationsDir / courtMigration, staging / courtMigration)
        migrate(up, staging)

        check up.queryOne(
          """select count(*)::int as total from session.games g
              where not exists (
                      select 1 from session.courts c
                       where c.community_id = g.community_id
                         and c.session_id = g.session_id
                         and c.court_index = g.court_no)""")
          .get.get("total") == "0"
        check up.queryOne(
          """select count(*)::int as total from session.game_skips k
              where not exists (
                      select 1 from session.courts c
                       where c.community_id = k.community_id
                         and c.session_id = k.session_id
                         and c.court_index = k.court_no)""")
          .get.get("total") == "0"
        # The row is derived from the session's own schedule, and it is not a
        # declared register, so the next coordinate does not have to be in it.
        let court = up.queryOne(
          """select court_index::text as idx, start_time::text as start_at,
                    end_time::text as end_at, declared::text as declared
               from session.courts
              where community_id = $1::uuid and session_id = $2::uuid
                and court_index = 3""",
          @[textParam(communityId), textParam(sessionId)]).get
        check court.get("start_at") == "18:00:00"
        check court.get("end_at") == "18:30:00"
        check court.get("declared") == "false"
        discard up.execUpdate(
          """insert into session.games
               (community_id, session_id, round_no, court_no, status)
             values ($1::uuid, $2::uuid, 2, 7, 'scheduled')""",
          @[textParam(communityId), textParam(sessionId)])
        check up.queryOne(
          """select count(*)::int as total from session.courts
              where community_id = $1::uuid and session_id = $2::uuid""",
          @[textParam(communityId), textParam(sessionId)]).get.get("total") == "3"
      finally:
        up.close()
        discard admin.execUpdate("drop database if exists " & courtName &
          " with (force)")

    test "a played game with no set cannot move into a rated session":
      # DB-08: marking a game played before its score is the host flag and is
      # allowed while the session is a draft. Leaving that state behind in a
      # session that rates the game is refused at the database.
      migrate(scratch, migrationsDir)
      let communityId = scratch.queryOne(
        """insert into platform.community (slug, name, timezone)
           values ('played-guard', 'Played Guard', 'Asia/Jakarta') returning id""")
        .get.get("id")
      let sessionId = scratch.queryOne(
        """insert into session.sessions
             (community_id, session_date, status, source)
           values ($1::uuid, '2026-11-04', 'draft', 'manual') returning id""",
        @[textParam(communityId)]).get.get("id")
      discard scratch.execUpdate(
        """insert into session.games
             (community_id, session_id, round_no, court_no, status)
           values ($1::uuid, $2::uuid, 0, 0, 'scheduled')""",
        @[textParam(communityId), textParam(sessionId)])
      discard scratch.execUpdate(
        """update session.games set status = 'played'
            where community_id = $1::uuid and session_id = $2::uuid""",
        @[textParam(communityId), textParam(sessionId)])

      # 0052 refuses the approval while that row exists...
      var state = ""
      try:
        discard scratch.execUpdate(
          """update session.sessions set status = 'locked'
              where community_id = $1::uuid and id = $2::uuid""",
          @[textParam(communityId), textParam(sessionId)])
      except DbError as error:
        state = error.sqlState
      check state == "23514"

      # ...and the game row itself refuses the transition once the session is
      # already rated, whichever writer makes it.
      let ratedSession = scratch.queryOne(
        """insert into session.sessions
             (community_id, session_date, status, source, approved_at)
           values ($1::uuid, '2026-11-04', 'locked', 'manual', now())
           returning id""",
        @[textParam(communityId)]).get.get("id")
      discard scratch.execUpdate(
        """insert into session.games
             (community_id, session_id, round_no, court_no, status)
           values ($1::uuid, $2::uuid, 0, 0, 'scheduled')""",
        @[textParam(communityId), textParam(ratedSession)])
      state = ""
      try:
        discard scratch.execUpdate(
          """update session.games set status = 'played'
              where community_id = $1::uuid and session_id = $2::uuid""",
          @[textParam(communityId), textParam(ratedSession)])
      except DbError as error:
        state = error.sqlState
      check state == "23514"

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

    test "a played game inserted outside a draft is refused at commit":
      # DB-08 closes at the insert as well. 0054 refused the transition; a row
      # that arrives already `played` was still accepted, which is the shape the
      # v1 import produced five of. The check is deferred to commit, so the
      # production order (game row, then its set, in one transaction) still
      # works, and a draft keeps the host flag `setPlayed` writes.
      migrate(scratch, migrationsDir)
      let communityId = scratch.queryOne(
        """insert into platform.community (slug, name, timezone)
           values ('played-insert', 'Played Insert', 'Asia/Jakarta') returning id""")
        .get.get("id")
      let lockedSession = scratch.queryOne(
        """insert into session.sessions
             (community_id, session_date, status, source, approved_at)
           values ($1::uuid, '2026-11-05', 'locked', 'manual', now())
           returning id""",
        @[textParam(communityId)]).get.get("id")

      # The bad shape commits on its own: a rated session, a played game, no set.
      var state = ""
      try:
        discard scratch.execUpdate(
          """insert into session.games
               (community_id, session_id, round_no, court_no, status)
             values ($1::uuid, $2::uuid, 0, 0, 'played')""",
          @[textParam(communityId), textParam(lockedSession)])
      except DbError as error:
        state = error.sqlState
      check state == "23514"

      # A draft is exempt: marking a game played before the score is the host
      # flag, and an unapproved session cannot be rated with one (0052).
      let draftSession = scratch.queryOne(
        """insert into session.sessions
             (community_id, session_date, status, source)
           values ($1::uuid, '2026-11-05', 'draft', 'manual') returning id""",
        @[textParam(communityId)]).get.get("id")
      discard scratch.execUpdate(
        """insert into session.games
             (community_id, session_id, round_no, court_no, status)
           values ($1::uuid, $2::uuid, 0, 0, 'played')""",
        @[textParam(communityId), textParam(draftSession)])

      # The production write order is game first, set second: one transaction,
      # so the deferred check sees both rows and lets it commit.
      scratch.tx(proc(conn: DbConn) =
        discard conn.execUpdate(
          """insert into session.games
               (community_id, session_id, round_no, court_no, status)
             values ($1::uuid, $2::uuid, 0, 0, 'played')""",
          @[textParam(communityId), textParam(lockedSession)])
        discard conn.execUpdate(
          """insert into session.game_sets
               (community_id, session_id, round_no, court_no, set_no,
                score_a, score_b)
             values ($1::uuid, $2::uuid, 0, 0, 1, 21, 15)""",
          @[textParam(communityId), textParam(lockedSession)]))
      check scratch.queryOne(
        """select count(*)::int as total from session.games
           where community_id = $1::uuid and session_id = $2::uuid""",
        @[textParam(communityId), textParam(lockedSession)])
        .get.get("total") == "1"

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

    test "deleting a rated source removes its event and sign-off":
      migrate(scratch, migrationsDir)
      let communityId = scratch.queryOne(
        """insert into platform.community (slug, name, timezone)
           values ('source-cascade', 'Source Cascade', 'Asia/Jakarta') returning id""")
        .get.get("id")
      let sessionId = scratch.queryOne(
        """insert into session.sessions
             (community_id, session_date, status, source)
           values ($1::uuid, '2026-11-02', 'locked', 'manual') returning id""",
        @[textParam(communityId)]).get.get("id")
      let tournamentId = scratch.queryOne(
        """insert into tournament.tournaments (community_id, name, status)
           values ($1::uuid, 'Cascade Cup', 'active') returning id""",
        @[textParam(communityId)]).get.get("id")
      for source in [sessionId, tournamentId]:
        let kind = if source == sessionId: "session" else: "tournament"
        discard scratch.execUpdate(
          """insert into rating.events (community_id, local_date, event_type, source_id)
             values ($1::uuid, '2026-11-02', $2, $3::uuid)""",
          @[textParam(communityId), textParam(kind), textParam(source)])
        discard scratch.execUpdate(
          """insert into rating.sources (community_id, source_id, kind)
             values ($1::uuid, $2::uuid, $3)""",
          @[textParam(communityId), textParam(source), textParam(kind)])

      discard scratch.execUpdate(
        "delete from session.sessions where community_id = $1::uuid and id = $2::uuid",
        @[textParam(communityId), textParam(sessionId)])
      check scratch.queryOne(
        "select count(*)::int as n from rating.events where source_id = $1::uuid",
        @[textParam(sessionId)]).get.get("n") == "0"
      check scratch.queryOne(
        "select count(*)::int as n from rating.sources where source_id = $1::uuid",
        @[textParam(sessionId)]).get.get("n") == "0"

      discard scratch.execUpdate(
        "delete from tournament.tournaments where community_id = $1::uuid and id = $2::uuid",
        @[textParam(communityId), textParam(tournamentId)])
      check scratch.queryOne(
        "select count(*)::int as n from rating.events where source_id = $1::uuid",
        @[textParam(tournamentId)]).get.get("n") == "0"

    test "an id the row does not supply is a UUIDv7":
      migrate(scratch, migrationsDir)
      let communityId = scratch.queryOne(
        """insert into platform.community (slug, name, timezone)
           values ('uuidv7-defaults', 'UUIDv7', 'Asia/Jakarta') returning id""")
        .get.get("id")
      let audit = scratch.queryOne(
        """insert into account.audit
             (actor_role, action, target_kind, target_id, result, request_id)
           values ('owner', 'uuidv7.test', 'test', 'x', 'allow', '-')
           returning id::text as id""").get.get("id")
      let event = scratch.queryOne(
        """insert into rating.events (community_id, local_date, event_type)
           values ($1::uuid, '2026-11-02', 'manual') returning id::text as id""",
        @[textParam(communityId)]).get.get("id")
      check audit[14] == '7'
      check event[14] == '7'

    test "the duplicate session indexes are gone and the strict ones remain":
      migrate(scratch, migrationsDir)
      let gone = @["games_round_court_unique", "courts_community_session_idx",
        "participants_community_session_idx",
        "game_skips_community_session_idx", "links_community_session_idx"]
      let kept = @["games_identity_unique", "courts_session_index_unique",
        "participants_session_player_unique", "game_skips_game_unique",
        "links_one_live"]
      for name in gone:
        check scratch.queryOne(
          """select 1 as ok from pg_indexes
             where schemaname = 'session' and indexname = $1""",
          @[textParam(name)]).isNone
      for name in kept:
        check scratch.queryOne(
          """select 1 as ok from pg_indexes
             where schemaname = 'session' and indexname = $1""",
          @[textParam(name)]).isSome

    test "config values must match their declared type and bounds":
      migrate(scratch, migrationsDir)
      var typeState = ""
      try:
        discard scratch.execUpdate(
          """insert into platform.config (key, value_type, value, scope)
             values ('t', 'int', '"x"', 'platform')""")
      except DbError as error:
        typeState = error.sqlState
      check typeState == "23514"
      var boundState = ""
      try:
        discard scratch.execUpdate(
          """insert into platform.config
               (key, value_type, value, min_value, max_value, scope)
             values ('t.bound', 'int', '999', 1, 10, 'platform')""")
      except DbError as error:
        boundState = error.sqlState
      check boundState == "23514"
      # The seed values pass the same checks on a fresh database.
      seed(scratch, seedsDir)
      let snapshot = loadSnapshot(scratch)
      check snapshot.values.len == allKeys.len

    test "the dead platform import map is gone and the real map remains":
      migrate(scratch, migrationsDir)
      check scratch.queryOne(
        """select 1 as ok from pg_class c
           join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'platform' and c.relname = 'import_row_map'""").isNone
      check scratch.queryOne(
        """select 1 as ok from pg_class c
           join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'import' and c.relname = 'row_map'""").isSome

    test "a badge key is catalogued or one of the two imported families":
      migrate(scratch, migrationsDir)
      let communityId = scratch.queryOne(
        """insert into platform.community (slug, name, timezone)
           values ('badge-keys', 'Badge Keys', 'Asia/Jakarta') returning id""")
        .get.get("id")
      let playerId = scratch.queryOne(
        """insert into player.players (community_id, canonical_name)
           values ($1::uuid, 'Badge Player') returning id""",
        @[textParam(communityId)]).get.get("id")
      discard scratch.execUpdate(
        """insert into achievement.definitions (key, category, threshold)
           values ('sessions:5', 'attendance', 5) on conflict do nothing""")
      for key in ["sessions:5", "tournament:abc", "rank_streak:99"]:
        discard scratch.execUpdate(
          """insert into achievement.earned
               (community_id, player_id, achievement_key)
             values ($1::uuid, $2::uuid, $3)""",
          @[textParam(communityId), textParam(playerId), textParam(key)])
      var state = ""
      try:
        discard scratch.execUpdate(
          """insert into achievement.earned
               (community_id, player_id, achievement_key)
             values ($1::uuid, $2::uuid, 'typo:1')""",
          @[textParam(communityId), textParam(playerId)])
      except DbError as error:
        state = error.sqlState
      check state == "23514"

    test "a team sheet accepts every tier the player ladder knows":
      migrate(scratch, migrationsDir)
      let communityId = scratch.queryOne(
        """insert into platform.community (slug, name, timezone)
           values ('team-class', 'Team Class', 'Asia/Jakarta') returning id""")
        .get.get("id")
      let playerId = scratch.queryOne(
        """insert into player.players (community_id, canonical_name, tier)
           values ($1::uuid, 'D Player', 'D') returning id""",
        @[textParam(communityId)]).get.get("id")
      let tournamentId = scratch.queryOne(
        """insert into tournament.tournaments (community_id, name, status)
           values ($1::uuid, 'Class Cup', 'active') returning id""",
        @[textParam(communityId)]).get.get("id")
      let teamId = scratch.queryOne(
        """insert into tournament.teams
             (community_id, tournament_id, seed, team_name)
           values ($1::uuid, $2::uuid, 1, 'Class Team') returning id""",
        @[textParam(communityId), textParam(tournamentId)]).get.get("id")
      discard scratch.execUpdate(
        """insert into tournament.team_players
             (community_id, team_id, player_id, player_name, cls)
           values ($1::uuid, $2::uuid, $3::uuid, 'D Player', 'D')""",
        @[textParam(communityId), textParam(teamId), textParam(playerId)])
      var state = ""
      try:
        discard scratch.execUpdate(
          """insert into tournament.team_players
               (community_id, team_id, player_name, cls)
             values ($1::uuid, $2::uuid, 'E Player', 'E')""",
          @[textParam(communityId), textParam(teamId)])
      except DbError as error:
        state = error.sqlState
      check state == "23514"

    test "the community timezone is a known zone and a court may cross midnight":
      migrate(scratch, migrationsDir)
      let communityId = scratch.queryOne(
        """insert into platform.community (slug, name, timezone)
           values ('zone-check', 'Zone Check', 'Asia/Jakarta') returning id""")
        .get.get("id")
      var state = ""
      try:
        discard scratch.execUpdate(
          "update platform.community set timezone = 'Asia/Jakrta' where id = $1::uuid",
          @[textParam(communityId)])
      except DbError as error:
        state = error.sqlState
      check state == "23514"
      check scratch.queryOne(
        """select 1 as ok from pg_timezone_names where name = 'Asia/Jakarta'""")
        .isSome

      let sessionId = scratch.queryOne(
        """insert into session.sessions
             (community_id, session_date, status, source)
           values ($1::uuid, '2026-11-02', 'draft', 'manual') returning id""",
        @[textParam(communityId)]).get.get("id")
      discard scratch.execUpdate(
        """insert into session.courts
             (community_id, session_id, court_index, court_name,
              start_time, end_time)
           values ($1::uuid, $2::uuid, 0, 'Late court', '22:00', '01:00')""",
        @[textParam(communityId), textParam(sessionId)])
      let court = scratch.queryOne(
        """select start_time::text as start_time, end_time::text as end_time
           from session.courts
           where community_id = $1::uuid and session_id = $2::uuid""",
        @[textParam(communityId), textParam(sessionId)]).get
      check court.get("start_time") == "22:00:00"
      check court.get("end_time") == "01:00:00"

    test "every table with updated_at bumps its version":
      migrate(scratch, migrationsDir)
      for table in ["tournament.matches", "tournament.pairs",
                    "tournament.teams", "tournament.team_partai"]:
        let parts = table.split('.')
        check scratch.queryOne(
          """select 1 as ok from information_schema.columns
             where table_schema = $1 and table_name = $2
               and column_name = 'version'""",
          @[textParam(parts[0]), textParam(parts[1])]).isSome
      let stamped = scratch.query(
        """select table_schema, table_name from information_schema.columns
           where column_name = 'updated_at'
             and table_schema in ('session', 'player', 'rating', 'tournament',
                                  'community')
           order by 1, 2""")
      check stamped.len >= 8
      for row in stamped:
        let found = scratch.queryOne(
          """select 1 as ok from pg_trigger t
             join pg_class c on c.oid = t.tgrelid
             join pg_namespace n on n.oid = c.relnamespace
             join pg_proc p on p.oid = t.tgfoid
             join pg_namespace pn on pn.oid = p.pronamespace
             where n.nspname = $1 and c.relname = $2
               and pn.nspname = 'session' and p.proname = 'bump_version'
               and not t.tgisinternal""",
          @[textParam(row.get("table_schema")), textParam(row.get("table_name"))])
        checkpoint(row.get("table_schema") & "." & row.get("table_name"))
        check found.isSome

      # One real match update proves the trigger is wired, not just present.
      let communityId = scratch.queryOne(
        """insert into platform.community (slug, name, timezone)
           values ('version-trigger', 'Version Trigger', 'Asia/Jakarta') returning id""")
        .get.get("id")
      var playerIds: seq[string] = @[]
      for name in ["Version A", "Version B", "Version C", "Version D"]:
        playerIds.add(scratch.queryOne(
          """insert into player.players (community_id, canonical_name)
             values ($1::uuid, $2) returning id""",
          @[textParam(communityId), textParam(name)]).get.get("id"))
      let tournamentId = scratch.queryOne(
        """insert into tournament.tournaments (community_id, name, status)
           values ($1::uuid, 'Version Cup', 'active') returning id""",
        @[textParam(communityId)]).get.get("id")
      var pairIds: seq[string] = @[]
      for index in 0 .. 1:
        pairIds.add(scratch.queryOne(
          """insert into tournament.pairs
               (community_id, tournament_id, display_name, player_a_id, player_b_id)
             values ($1::uuid, $2::uuid, $3, $4::uuid, $5::uuid) returning id""",
          @[textParam(communityId), textParam(tournamentId),
            textParam("Version Pair " & $index), textParam(playerIds[index * 2]),
            textParam(playerIds[index * 2 + 1])]).get.get("id"))
      let matchId = scratch.queryOne(
        """insert into tournament.matches
             (community_id, tournament_id, round_no, pair_a_id, pair_b_id)
           values ($1::uuid, $2::uuid, 1, $3::uuid, $4::uuid) returning id""",
        @[textParam(communityId), textParam(tournamentId), textParam(pairIds[0]),
          textParam(pairIds[1])]).get.get("id")
      discard scratch.execUpdate(
        """update tournament.matches
           set score_a = 21, score_b = 15, status = 'played'
           where community_id = $1::uuid and id = $2::uuid""",
        @[textParam(communityId), textParam(matchId)])
      check scratch.queryOne(
        """select version from tournament.matches
           where community_id = $1::uuid and id = $2::uuid""",
        @[textParam(communityId), textParam(matchId)]).get.get("version") == "2"
finally:
  shutdown()