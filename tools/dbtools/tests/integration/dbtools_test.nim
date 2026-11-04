import std/[options, os, strutils, unittest]
import db/db
import ../../main

proc dsn(): string =
  getEnv("MAJADU_PG_DSN")

suite "dbtools":
  var db: Db
  const migrations = "tools/dbtools/tests/fixtures/migrations"
  const seeds = "tools/dbtools/tests/fixtures/seeds"

  # The suite owns the whole ledger schema, so it must not run against the
  # database the application uses: dropping `dbtools` would erase the real
  # migration history. The rows are saved here and restored in teardown.
  var savedMigrations: seq[(string, string)] = @[]
  var savedSeeds: seq[(string, string)] = @[]

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    savedMigrations.setLen(0)
    savedSeeds.setLen(0)
    db = openDb(dsn(), 1)
    if db.queryOne("""select 1 as ok from information_schema.tables
                      where table_schema = 'dbtools'
                        and table_name = 'schema_migrations'""").isSome:
      for row in db.query("select version, checksum from dbtools.schema_migrations"):
        savedMigrations.add((row.get("version"), row.get("checksum")))
    if db.queryOne("""select 1 as ok from information_schema.tables
                      where table_schema = 'dbtools'
                        and table_name = 'seed_files'""").isSome:
      for row in db.query("select name, checksum from dbtools.seed_files"):
        savedSeeds.add((row.get("name"), row.get("checksum")))
    discard db.execUpdate("drop schema if exists dbtools cascade")
    discard db.execUpdate("drop table if exists probe cascade")

  teardown:
    discard db.execUpdate("drop schema if exists dbtools cascade")
    if savedMigrations.len > 0 or savedSeeds.len > 0:
      discard db.tx(proc(conn: DbConn): int =
        conn.execScript(ledgerSchema)
        for (version, sum) in savedMigrations:
          discard conn.execUpdate(
            "insert into dbtools.schema_migrations (version, checksum) values ($1, $2)",
            @[textParam(version), textParam(sum)])
        for (name, sum) in savedSeeds:
          discard conn.execUpdate(
            "insert into dbtools.seed_files (name, checksum) values ($1, $2)",
            @[textParam(name), textParam(sum)])
        1)
    db.close()

  test "migrate is idempotent and records checksums":
    migrate(db, migrations)
    migrate(db, migrations)
    let row = db.queryOne(
      "select count(*) as total from dbtools.schema_migrations").get
    check row.get("total") == "2"

  test "verify is clean after migrate":
    migrate(db, migrations)
    check verifyProblems(db, migrations).len == 0

  test "verify reports checksum drift":
    migrate(db, migrations)
    let tampered = getTempDir() / "dbtools-tampered"
    if dirExists(tampered):
      removeDir(tampered)
    copyDir(migrations, tampered)
    writeFile(tampered / "0001_probe.sql",
      readFile(tampered / "0001_probe.sql") & "\n-- tampered\n")
    let problems = verifyProblems(db, tampered)
    check problems.len == 1
    check problems[0].contains("checksum drift: 0001_probe")
    removeDir(tampered)

  test "verify reports a pending migration":
    migrate(db, migrations)
    let extra = getTempDir() / "dbtools-pending"
    if dirExists(extra):
      removeDir(extra)
    copyDir(migrations, extra)
    writeFile(extra / "0003_late.sql", "select 1;")
    let problems = verifyProblems(db, extra)
    check problems.len == 1
    check problems[0].contains("pending migration: 0003_late")
    removeDir(extra)

  test "seed runs once":
    migrate(db, migrations)
    seed(db, seeds)
    seed(db, seeds)
    let row = db.queryOne("select count(*) as total from probe").get
    check row.get("total") == "1"
