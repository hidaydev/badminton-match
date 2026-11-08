import std/[options, os, osproc, strutils, unittest]
import db/db
import ../../main

proc dsn(): string =
  getEnv("MAJADU_PG_DSN")

proc repoRoot(): string =
  ## The CLI half runs the compiled tool, which has to be built from the
  ## repository root so `config.nims` supplies the module paths.
  var dir = currentSourcePath().parentDir
  for _ in 0 ..< 8:
    if fileExists(dir / "tools/dbtools/main.nim"):
      return dir
    let parent = parentDir(dir)
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot find the repository root from " & currentSourcePath())

proc toolBinary(): string =
  ## `./task check` compiles suites, not the tools, so the two usage cases drive
  ## a binary built once here. `DBTOOLS_BIN` lets a run reuse one it built.
  var built {.global.}: string
  if built.len > 0:
    return built
  let fromEnv = getEnv("DBTOOLS_BIN")
  if fromEnv.len > 0 and fileExists(fromEnv):
    return fromEnv
  let root = repoRoot()
  let directory = getTempDir() / ("majadu-dbtools-cli-" & $getCurrentProcessId())
  createDir(directory)
  built = directory / "dbtools"
  let (output, code) = execCmdEx("nim c --hints:off --nimcache:" &
    quoteShell(directory / "nimcache") & " -o:" & quoteShell(built) & " " &
    quoteShell(root / "tools/dbtools/main.nim"), workingDir = root)
  if code != 0 or not fileExists(built):
    raise newException(IOError, "cannot build dbtools:\n" & output)
  built

proc runCli(arguments: string): tuple[output: string, exitCode: int] =
  execCmdEx(quoteShell(toolBinary()) & " " & arguments, workingDir = repoRoot())

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
      db.tx(proc(conn: DbConn) =
        conn.execScript(ledgerSchema)
        for (version, sum) in savedMigrations:
          discard conn.execUpdate(
            "insert into dbtools.schema_migrations (version, checksum) values ($1, $2)",
            @[textParam(version), textParam(sum)])
        for (name, sum) in savedSeeds:
          discard conn.execUpdate(
            "insert into dbtools.seed_files (name, checksum) values ($1, $2)",
            @[textParam(name), textParam(sum)])
      )
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

  test "a contract migration only runs with the flag":
    migrate(db, migrations)
    let contract = getTempDir() / "dbtools-contract-migrate"
    if dirExists(contract):
      removeDir(contract)
    copyDir(migrations, contract)
    writeFile(contract / "0003_contract.sql",
      "-- 0003: rewrite the probe once the previous release stopped reading it.\n" &
      "-- contract\n\n" &
      "create table if not exists contract_probe (id int);\n" &
      "drop table contract_probe;\n")
    check contractRefusal(contract, false).contains("0003_contract.sql")
    check contractRefusal(contract, true).len == 0
    migrate(db, contract, allowContract = true)
    check verifyProblems(db, contract).len == 0
    removeDir(contract)

  test "seed runs once":
    migrate(db, migrations)
    seed(db, seeds)
    seed(db, seeds)
    let row = db.queryOne("select count(*) as total from probe").get
    check row.get("total") == "1"

  test "an edited seed is applied again and records its new checksum":
    migrate(db, migrations)
    let edited = getTempDir() / "dbtools-seed-edit"
    if dirExists(edited):
      removeDir(edited)
    copyDir(seeds, edited)
    seed(db, edited)
    let before = db.queryOne(
      "select checksum from dbtools.seed_files where name = '001_probe.sql'").get
    # The edit adds a row, so "the statement ran" is visible in the table as
    # well as in the checksum: an unchanged file would leave both untouched.
    writeFile(edited / "001_probe.sql", readFile(edited / "001_probe.sql") &
      "\ninsert into probe (id, note) values (2, 'edited')" &
      " on conflict (id) do nothing;\n")
    seed(db, edited)
    let after = db.queryOne(
      "select checksum from dbtools.seed_files where name = '001_probe.sql'").get
    check after.get("checksum") != before.get("checksum")
    let total = db.queryOne("select count(*)::int as n from probe").get
    check total.get("n") == "2"
    removeDir(edited)

  test "an unchanged seed writes nothing on the second run":
    migrate(db, migrations)
    seed(db, seeds)
    # A fixed timestamp makes "nothing was written" observable: the ledger
    # upsert records now() whenever it runs.
    discard db.execUpdate(
      """update dbtools.seed_files set applied_at = '2020-01-01T00:00:00Z'
         where name = '001_probe.sql'""")
    seed(db, seeds)
    let row = db.queryOne(
      """select applied_at = '2020-01-01T00:00:00Z'::timestamptz as untouched
         from dbtools.seed_files where name = '001_probe.sql'""").get
    check row.get("untouched") == "t"

  test "an applied migration whose file is gone is reported":
    migrate(db, migrations)
    let trimmed = getTempDir() / "dbtools-missing"
    if dirExists(trimmed):
      removeDir(trimmed)
    createDir(trimmed)
    copyFile(migrations / "0001_probe.sql", trimmed / "0001_probe.sql")
    check verifyProblems(db, trimmed) ==
      @["applied migration has no file: 0002_probe_index"]
    removeDir(trimmed)

  test "migrate over an empty directory exits 1 naming the directory":
    let empty = getTempDir() / "dbtools-empty"
    if dirExists(empty):
      removeDir(empty)
    createDir(empty)
    let run = runCli("migrate --dir " & quoteShell(empty))
    check run.exitCode == 1
    check run.output.contains("no .sql files in " & empty)
    removeDir(empty)

  test "seed refuses --allow-contract with exit 2":
    let run = runCli("seed --allow-contract")
    check run.exitCode == 2
    check run.output.contains("--allow-contract only applies to migrate")
