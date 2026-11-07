## The migration runner: `migrate`, `verify` and `seed` over `db/migrations`.
##
## A release only expands the schema. Deploy applies the migrations in the new
## image while the previous image still serves, so a migration that removes or
## rewrites what `:prev` reads is a deliberate, separate step. Such a file says
## so in its header, on a line of its own:
##
##   -- contract
##
## `migrate` refuses a file carrying that marker unless `--allow-contract` is
## passed; `deploy-vps.sh` never passes it. The operator applies it by hand
## (`dbtools migrate --allow-contract`), one release after the deploy that
## stopped writing the old shape. Only the leading comment block is read, so a
## later mention of the word does not opt a file in.
##
## `create index concurrently` stays a manual operation and is not supported
## here: every migration runs inside one transaction with an advisory lock, and
## `CONCURRENTLY` cannot run in a transaction. An index big enough to need it is
## created by the operator before the release; the shipped migration is
## `create index if not exists`, which then does nothing.
import std/[algorithm, options, os, strutils]
import cli
import db/db
import sha256

const
  program = "dbtools"
  contractMarker = "-- contract"
  ledgerSchema* = """
set client_min_messages to warning;
create schema if not exists dbtools;
create table if not exists dbtools.schema_migrations (
  version text primary key,
  checksum text not null,
  applied_at timestamptz not null default now()
);
create table if not exists dbtools.seed_files (
  name text primary key,
  checksum text not null,
  applied_at timestamptz not null default now()
);
"""

type
  Migration = object
    version: string
    path: string
    checksum: string
    contract: bool

proc sqlFiles(dir: string): seq[string] =
  if not dirExists(dir):
    fail(program, "directory not found: " & dir)
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".sql"):
      result.add(path)
  result.sort()

proc checksum(path: string): string =
  sha256Hex(readFile(path))

proc hasContractHeader(body: string): bool =
  ## True when a line of the leading comment block is exactly `-- contract`.
  ## The header ends at the first line that neither is a comment nor blank.
  for line in body.splitLines():
    let stripped = line.strip()
    if stripped.len == 0:
      continue
    if not stripped.startsWith("--"):
      break
    if stripped == contractMarker:
      return true

proc loadMigrations(dir: string): seq[Migration] =
  for path in sqlFiles(dir):
    # One read decides both the checksum and the marker, so the two can never
    # describe different bytes of the same file.
    let body = readFile(path)
    result.add(Migration(
      version: path.extractFilename.changeFileExt(""),
      path: path,
      checksum: sha256Hex(body),
      contract: hasContractHeader(body),
    ))

proc contractMessage(path: string): string =
  path & " is marked `" & contractMarker & "`; it is applied by hand with " &
    "`dbtools migrate --allow-contract`, one release after the deploy that " &
    "stopped using the old shape"

proc contractProblem(allowContract: bool, migrations: openArray[Migration]): string =
  if allowContract:
    return ""
  for migration in migrations:
    if migration.contract:
      return contractMessage(migration.path)

proc contractRefusal*(dir: string, allowContract: bool): string =
  ## Why `migrate` must not run over `dir`, or "" when it may. A contract file
  ## is only let through by the explicit flag; a file that cannot be read is a
  ## refusal too, so a failed read never reads as "nothing to refuse".
  try:
    contractProblem(allowContract, loadMigrations(dir))
  except CatchableError as error:
    "cannot read " & dir & ": " & error.msg

proc ensureLedger(conn: DbConn) =
  conn.execScript(ledgerSchema)

proc applied(conn: DbConn): seq[(string, string)] =
  for row in conn.query("select version, checksum from dbtools.schema_migrations"):
    result.add((row.get("version"), row.get("checksum")))

proc migrate*(db: Db, dir: string, allowContract = false) =
  let migrations = loadMigrations(dir)
  if migrations.len == 0:
    fail(program, "no .sql files in " & dir)
  let refusal = contractProblem(allowContract, migrations)
  if refusal.len > 0:
    fail(program, refusal)

  db.tx(proc(conn: DbConn) =
    # One transaction and one advisory lock: two deploys cannot interleave.
    discard conn.query("select pg_advisory_xact_lock(hashtext('majadu-dbtools'))")
    ensureLedger(conn)
    var known: seq[(string, string)] = @[]
    for row in conn.query("select version, checksum from dbtools.schema_migrations"):
      known.add((row.get("version"), row.get("checksum")))

    for migration in migrations:
      var existing = ""
      for (version, sum) in known:
        if version == migration.version:
          existing = sum
      if existing.len > 0:
        if existing != migration.checksum:
          fail(program, "checksum drift: " & migration.version &
            " was applied with a different body")
        continue
      conn.execScript(readFile(migration.path))
      discard conn.execUpdate(
        "insert into dbtools.schema_migrations (version, checksum) values ($1, $2)",
        @[textParam(migration.version), textParam(migration.checksum)],
      )
  )
  echo "dbtools: migrated " & $migrations.len & " file(s)"

proc verifyProblems*(db: Db, dir: string): seq[string] =
  let migrations = loadMigrations(dir)
  let rows = db.txRet(proc(conn: DbConn): seq[(string, string)] =
    ensureLedger(conn)
    applied(conn)
  )
  var appliedVersions: seq[string] = @[]
  for (version, sum) in rows:
    appliedVersions.add(version)
    var found = false
    for migration in migrations:
      if migration.version == version:
        found = true
        if migration.checksum != sum:
          result.add("checksum drift: " & version)
    if not found:
      result.add("applied migration has no file: " & version)
  for migration in migrations:
    if migration.version notin appliedVersions:
      result.add("pending migration: " & migration.version)

proc verify*(db: Db, dir: string) =
  let migrations = loadMigrations(dir)
  let problems = verifyProblems(db, dir)
  if problems.len > 0:
    for problem in problems:
      stderr.writeLine "dbtools: " & problem
    fail(program, $problems.len &
      " problem(s); database is not at the committed schema")
  echo "dbtools: verified " & $migrations.len & " file(s)"

proc seed*(db: Db, dir: string) =
  let files = sqlFiles(dir)
  if files.len == 0:
    fail(program, "no .sql files in " & dir)
  db.tx(proc(conn: DbConn) =
    discard conn.query("select pg_advisory_xact_lock(hashtext('majadu-dbtools'))")
    ensureLedger(conn)
    for path in files:
      let name = path.extractFilename
      let sum = checksum(path)
      let existing = conn.queryOne(
        "select checksum from dbtools.seed_files where name = $1", @[textParam(name)])
      # Seeds are idempotent by construction (INSERT ... ON CONFLICT DO
      # NOTHING), so a changed file is applied again and the ledger records the
      # new checksum. Operator edits to existing values survive; new rows land.
      if existing.isSome and existing.get.get("checksum") == sum:
        continue
      conn.execScript(readFile(path))
      discard conn.execUpdate(
        """insert into dbtools.seed_files (name, checksum, applied_at)
           values ($1, $2, now())
           on conflict (name) do update
             set checksum = excluded.checksum, applied_at = excluded.applied_at""",
        @[textParam(name), textParam(sum)],
      )
  )
  echo "dbtools: seeded " & $files.len & " file(s)"

proc usage() =
  echo """Usage: dbtools <migrate|verify|seed> [--dir <path>] [--allow-contract]

  migrate   apply pending .sql files in order, atomically
  verify    fail on checksum drift, missing files or pending migrations
  seed      apply .sql files once, tracked by name and checksum

Default directories: db/migrations (migrate/verify), db/seeds (seed).
--allow-contract lets migrate apply a file marked `-- contract`; deploy never
passes it. Environment: MAJADU_PG_DSN."""

proc main() =
  if paramCount() < 1:
    usage()
    quit(2)
  let command = paramStr(1)
  var dir = ""
  var allowContract = false
  for (flag, value) in flags(program, 2, ["--dir"]):
    case flag
    of "--dir":
      dir = value
    of "--allow-contract":
      allowContract = true
    else:
      usageFail(program, "unknown argument: " & flag)
  if allowContract and command != "migrate":
    usageFail(program, "--allow-contract only applies to migrate")
  if dir.len == 0:
    dir = if command == "seed": "db/seeds" else: "db/migrations"

  let database = openDb(dsnOrFail(program), 1)
  try:
    case command
    of "migrate": migrate(database, dir, allowContract)
    of "verify": verify(database, dir)
    of "seed": seed(database, dir)
    else:
      usage()
      quit(2)
  finally:
    database.close()
  quit(0)

when isMainModule:
  main()
