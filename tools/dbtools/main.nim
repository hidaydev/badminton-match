import std/[algorithm, options, os, strutils]
import db/db
import sha256

const
  ledgerSchema = """
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

proc fail(message: string) {.noreturn.} =
  stderr.writeLine "dbtools: " & message
  quit(1)

proc dsn(): string =
  result = getEnv("MAJADU_PG_DSN")
  if result.len == 0:
    fail "MAJADU_PG_DSN is required"

proc sqlFiles(dir: string): seq[string] =
  if not dirExists(dir):
    fail "directory not found: " & dir
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".sql"):
      result.add(path)
  result.sort()

proc checksum(path: string): string =
  sha256Hex(readFile(path))

proc loadMigrations(dir: string): seq[Migration] =
  for path in sqlFiles(dir):
    result.add(Migration(
      version: path.extractFilename.changeFileExt(""),
      path: path,
      checksum: checksum(path),
    ))

proc ensureLedger(conn: DbConn) =
  conn.execScript(ledgerSchema)

proc applied(conn: DbConn): seq[(string, string)] =
  for row in conn.query("select version, checksum from dbtools.schema_migrations"):
    result.add((row.get("version"), row.get("checksum")))

proc migrate*(db: Db, dir: string) =
  let migrations = loadMigrations(dir)
  if migrations.len == 0:
    fail "no .sql files in " & dir

  discard db.tx(proc(conn: DbConn): int =
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
          fail "checksum drift: " & migration.version & " was applied with a different body"
        continue
      conn.execScript(readFile(migration.path))
      discard conn.execUpdate(
        "insert into dbtools.schema_migrations (version, checksum) values ($1, $2)",
        @[textParam(migration.version), textParam(migration.checksum)],
      )
    1
  )
  echo "dbtools: migrated " & $migrations.len & " file(s)"

proc verifyProblems*(db: Db, dir: string): seq[string] =
  let migrations = loadMigrations(dir)
  let rows = db.tx(proc(conn: DbConn): seq[(string, string)] =
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
    fail $problems.len & " problem(s); database is not at the committed schema"
  echo "dbtools: verified " & $migrations.len & " file(s)"

proc seed*(db: Db, dir: string) =
  let files = sqlFiles(dir)
  if files.len == 0:
    fail "no .sql files in " & dir
  discard db.tx(proc(conn: DbConn): int =
    discard conn.query("select pg_advisory_xact_lock(hashtext('majadu-dbtools'))")
    ensureLedger(conn)
    for path in files:
      let name = path.extractFilename
      let sum = checksum(path)
      let existing = conn.queryOne(
        "select checksum from dbtools.seed_files where name = $1", @[textParam(name)])
      if existing.isSome:
        if existing.get.get("checksum") != sum:
          fail "seed drift: " & name
        continue
      conn.execScript(readFile(path))
      discard conn.execUpdate(
        "insert into dbtools.seed_files (name, checksum) values ($1, $2)",
        @[textParam(name), textParam(sum)],
      )
    1
  )
  echo "dbtools: seeded " & $files.len & " file(s)"

proc usage() =
  echo """Usage: dbtools <migrate|verify|seed> [--dir <path>]

  migrate   apply pending .sql files in order, atomically
  verify    fail on checksum drift, missing files or pending migrations
  seed      apply .sql files once, tracked by name and checksum

Default directories: db/migrations (migrate/verify), db/seeds (seed).
Environment: MAJADU_PG_DSN."""

proc main() =
  if paramCount() < 1:
    usage()
    quit(2)
  let command = paramStr(1)
  var dir = ""
  var i = 2
  while i <= paramCount():
    case paramStr(i)
    of "--dir":
      i.inc
      if i > paramCount(): fail "--dir needs a path"
      dir = paramStr(i)
    else:
      fail "unknown argument: " & paramStr(i)
    i.inc
  if dir.len == 0:
    dir = if command == "seed": "db/seeds" else: "db/migrations"

  let database = openDb(dsn(), 1)
  try:
    case command
    of "migrate": migrate(database, dir)
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
