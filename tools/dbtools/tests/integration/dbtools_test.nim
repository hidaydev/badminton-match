import std/[options, os, strutils, unittest]
import db/db
import ../../main

proc dsn(): string =
  getEnv("MAJADU_PG_DSN")

suite "dbtools":
  var db: Db
  const migrations = "tools/dbtools/tests/fixtures/migrations"
  const seeds = "tools/dbtools/tests/fixtures/seeds"

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    discard db.execUpdate("drop schema if exists dbtools cascade")
    discard db.execUpdate("drop table if exists probe cascade")

  teardown:
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
