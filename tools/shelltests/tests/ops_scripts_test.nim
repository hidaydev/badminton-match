# TL-19: the operator scripts that run without a VPS (`ops/scripts/backup.sh`,
# `restore.sh`, `rotate-log.sh`, `smoke.sh`, `deploy-dispatch.sh`).
#
# Every case keeps the script inside a temp `MAJADU_APP_DIR` and answers its
# external commands (`pg_dump`, `pg_restore`, `psql`, `curl`) with fakes on the
# fixture PATH, so no case reads or writes `/srv`, a database or a real host.

import std/[algorithm, os, strutils, times, unittest]
import ../harness

const okFake = """#!/bin/sh
exit 0
"""

const dumpFake = """#!/bin/sh
printf 'fake custom-format dump\n'
exit 0
"""

const psqlLogFake = """#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_PSQL_LOG"
exit 0
"""

const flockFake = """#!/bin/sh
# Stand-in for flock(1): a case sets FAKE_LOCK_HELD=1 to stand in for another
# deploy or cutover holding .deploy.lock.
if [ "${FAKE_LOCK_HELD:-0}" = "1" ]; then
  exit 1
fi
exit 0
"""

const smokeCurl = """#!/bin/sh
status=0
url=
for arg in "$@"; do
  case "$arg" in
    -w) ;;
    '%{http_code}') status=1 ;;
    http://*|https://*) url=$arg ;;
  esac
done
if [ "$status" -eq 1 ]; then
  case "$url" in
    */readyz) printf '200' ;;
    */metrics) printf '404' ;;
    */s/*) printf '404' ;;
    */auth/me) printf '401' ;;
    *) printf '200' ;;
  esac
  exit 0
fi
case "$url" in
  */version) printf '{"version":"%s"}' "${FAKE_CURL_VERSION-2.0.0}" ;;
  */healthz) printf '{"status":"ok"}' ;;
  *) printf '' ;;
esac
exit 0
"""

proc touch(path: string, body = "") =
  createDir(path.parentDir)
  writeFile(path, body)

proc age(path: string, days: int) =
  setLastModificationTime(path, getTime() - initDuration(days = days))

proc appDir(fixture: Fixture): seq[(string, string)] =
  @[("MAJADU_APP_DIR", fixture.root)]

proc mode600(path: string): bool =
  getFilePermissions(path) == {fpUserRead, fpUserWrite}

proc hasStampName(name, prefix: string): bool =
  ## `<prefix>YYYYmmdd-HHMMSS.dump`
  if not name.startsWith(prefix) or not name.endsWith(".dump"):
    return false
  let middle = name[prefix.len ..< name.len - len(".dump")]
  middle.len == 15 and middle[8] == '-' and
    middle[0 .. 7].allCharsInSet({'0' .. '9'}) and
    middle[9 .. 14].allCharsInSet({'0' .. '9'})

suite "backup.sh":
  test "--tag without a value exits 2":
    let fixture = newFixture("backup-tag-value")
    defer: removeDir(fixture.root)
    let result = fixture.runShell(fixture.installOpsScript("backup.sh"),
      @["--tag"], appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains("backup: --tag needs a value")

  test "an unknown argument exits 2":
    let fixture = newFixture("backup-arg")
    defer: removeDir(fixture.root)
    let result = fixture.runShell(fixture.installOpsScript("backup.sh"),
      @["--wat"], appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains("backup: unknown argument --wat")

  test "a tagged dump keeps the tag in its name and is mode 600":
    let fixture = newFixture("backup-tag")
    defer: removeDir(fixture.root)
    fixture.installFake("pg_dump", dumpFake)
    fixture.installFake("pg_restore", okFake)
    let backups = fixture.root / "backups"
    let result = fixture.runShell(fixture.installOpsScript("backup.sh"),
      @["--tag", "cutover"], appDir(fixture) & @[
        ("MAJADU_BACKUP_DIR", backups),
        ("MAJADU_BACKUP_DSN_BM2", "postgresql://bm2_owner@127.0.0.1:5432/bm2"),
      ])
    check result.exitCode == 0
    var dumps: seq[string]
    for kind, path in walkDir(backups):
      if kind == pcFile:
        dumps.add(path.extractFilename)
    check dumps.len == 1
    check hasStampName(dumps[0], "bm2-cutover-")
    check mode600(backups / dumps[0])
    check result.stdout.contains("wrote " & backups / dumps[0])

  test "an unreadable dump is deleted and exits 1":
    let fixture = newFixture("backup-unreadable")
    defer: removeDir(fixture.root)
    fixture.installFake("pg_dump", dumpFake)
    fixture.installFake("pg_restore", "#!/bin/sh\nexit 1\n")
    let backups = fixture.root / "backups"
    let result = fixture.runShell(fixture.installOpsScript("backup.sh"),
      @[], appDir(fixture) & @[
        ("MAJADU_BACKUP_DIR", backups),
        ("MAJADU_BACKUP_DSN_BM2", "postgresql://bm2_owner@127.0.0.1:5432/bm2"),
      ])
    check result.exitCode == 1
    check result.stderr.contains("bm2 dump is not readable; refusing to keep it")
    var leftovers: seq[string]
    for kind, path in walkDir(backups):
      if kind == pcFile:
        leftovers.add(path.extractFilename)
    check leftovers.len == 0

  test "pruning deletes old timestamped dumps and keeps a tagged one":
    let fixture = newFixture("backup-prune")
    defer: removeDir(fixture.root)
    fixture.installFake("pg_dump", dumpFake)
    fixture.installFake("pg_restore", okFake)
    let backups = fixture.root / "backups"
    createDir(backups)
    let oldPlain = backups / "bm2-20250101-000000.dump"
    let oldTagged = backups / "bm2-cutover-20250101-000000.dump"
    let oldJunk = backups / "bm2-notes.txt"
    for path in [oldPlain, oldTagged, oldJunk]:
      touch(path, "old")
      age(path, 30)
    let result = fixture.runShell(fixture.installOpsScript("backup.sh"),
      @[], appDir(fixture) & @[
        ("MAJADU_BACKUP_DIR", backups),
        ("MAJADU_BACKUP_DSN_BM2", "postgresql://bm2_owner@127.0.0.1:5432/bm2"),
        ("MAJADU_BACKUP_KEEP_DAYS", "7"),
      ])
    check result.exitCode == 0
    check not fileExists(oldPlain)
    check fileExists(oldTagged)
    check fileExists(oldJunk)
    var fresh: seq[string]
    for kind, path in walkDir(backups):
      if kind == pcFile and path.extractFilename notin
          [oldTagged.extractFilename, oldJunk.extractFilename]:
        fresh.add(path.extractFilename)
    check fresh.len == 1
    check hasStampName(fresh[0], "bm2-")

  test "bm2 is dumped as the owner DSN from the tool env":
    let fixture = newFixture("backup-owner-env")
    defer: removeDir(fixture.root)
    let dumpLog = fixture.root / "dump.log"
    fixture.installFake("pg_dump",
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$FAKE_DUMP_LOG\"\nprintf 'dump'\n")
    fixture.installFake("pg_restore", okFake)
    let tools = fixture.root / "env" / "majadu-tools.env"
    touch(tools,
      "MAJADU_OWNER_DSN=postgresql://bm2_owner@127.0.0.1:5432/bm2\n")
    let result = fixture.runShell(fixture.installOpsScript("backup.sh"),
      @[], appDir(fixture) & @[
        ("MAJADU_TOOLS_ENV", tools),
        ("MAJADU_BACKUP_DIR", fixture.root / "backups"),
        ("FAKE_DUMP_LOG", dumpLog),
      ])
    check result.exitCode == 0
    check readFile(dumpLog).contains("bm2_owner")

suite "restore.sh":
  test "a target outside the allowlist exits 2":
    let fixture = newFixture("restore-target")
    defer: removeDir(fixture.root)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "otherdb"], appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains("restore: refusing to write into 'otherdb'")

  test "bm and bm2 are refused without --force":
    let fixture = newFixture("restore-force")
    defer: removeDir(fixture.root)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    for target in ["bm", "bm2"]:
      let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
        @["--file", dump, "--target", target], appDir(fixture))
      check result.exitCode == 2
      check result.stderr.contains("'" & target &
        "' is production or archive; pass --force to write into it")

  test "bm2 is restored with --force":
    let fixture = newFixture("restore-force-ok")
    defer: removeDir(fixture.root)
    fixture.installFake("pg_restore", okFake)
    fixture.installFake("flock", flockFake)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm2", "--force"], appDir(fixture))
    check result.exitCode == 0
    check result.stdout.contains("restore: writing " & dump & " into bm2")
    check result.stdout.contains("restore: done")

  test "a --dsn that names another database is refused":
    let fixture = newFixture("restore-dsn-mismatch")
    defer: removeDir(fixture.root)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging",
        "--dsn", "postgres://bm2_owner@db.example:5432/bm2"], appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains(
      "restore: --target 'bm_staging' does not match the database 'bm2' in --dsn")
    check result.stderr.contains("refusing to write into 'bm2'")

  test "a matching --dsn with --force is still accepted":
    let fixture = newFixture("restore-dsn-match")
    defer: removeDir(fixture.root)
    fixture.installFake("pg_restore", okFake)
    fixture.installFake("flock", flockFake)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm2", "--force",
        "--dsn", "postgres://bm2_owner@db.example:5432/bm2?sslmode=require"],
      appDir(fixture))
    check result.exitCode == 0
    check result.stdout.contains("restore: writing " & dump & " into bm2")

  test "a dbname parameter cannot redirect the write":
    let fixture = newFixture("restore-dsn-dbname")
    defer: removeDir(fixture.root)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging",
        "--dsn", "postgres://u@db.example:5432/bm_staging?dbname=bm2"],
      appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains(
      "connection parameter 'dbname' in --dsn can change the destination")
    check result.stderr.contains("only sslmode is allowed")

  test "a mixed-case dbname parameter is refused":
    let fixture = newFixture("restore-dsn-dbname-case")
    defer: removeDir(fixture.root)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging",
        "--dsn", "postgres://u@db.example:5432/bm_staging?DbName=bm2"],
      appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains(
      "connection parameter 'DbName' in --dsn can change the destination")
    check result.stderr.contains("only sslmode is allowed")

  test "a percent-encoded dbname parameter is refused":
    let fixture = newFixture("restore-dsn-dbname-encoded")
    defer: removeDir(fixture.root)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging",
        "--dsn", "postgres://u@db.example:5432/bm_staging?%64bname=bm2"],
      appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains(
      "connection parameter 'dbname' in --dsn can change the destination")
    check result.stderr.contains("only sslmode is allowed")

  test "an undecodable parameter is refused":
    let fixture = newFixture("restore-dsn-bad-escape")
    defer: removeDir(fixture.root)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging",
        "--dsn", "postgres://u@db.example:5432/bm_staging?%zz=1"],
      appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains("cannot decode connection parameter '%zz'")

  test "sslmode is the only allowed query parameter":
    let fixture = newFixture("restore-dsn-sslmode")
    defer: removeDir(fixture.root)
    fixture.installFake("pg_restore", okFake)
    fixture.installFake("flock", flockFake)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging",
        "--dsn", "postgres://u@db.example:5432/bm_staging?sslmode=require"],
      appDir(fixture))
    check result.exitCode == 0
    check result.stdout.contains("restore: writing " & dump & " into bm_staging")

  test "an empty query string is accepted":
    let fixture = newFixture("restore-dsn-empty-query")
    defer: removeDir(fixture.root)
    fixture.installFake("pg_restore", okFake)
    fixture.installFake("flock", flockFake)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging",
        "--dsn", "postgres://u@db.example:5432/bm_staging?"],
      appDir(fixture))
    check result.exitCode == 0
    check result.stdout.contains("restore: writing " & dump & " into bm_staging")

  test "a question mark in the password is not a query":
    let fixture = newFixture("restore-dsn-password-question")
    defer: removeDir(fixture.root)
    let pgLog = fixture.root / "pg_restore.log"
    fixture.installFake("pg_restore",
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " & pgLog & "\nexit 0\n")
    fixture.installFake("flock", flockFake)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    # The `?` is in the userinfo, before the path slash, so it is password text.
    let dsn = "postgres://u:p?ss@db.example:5432/bm_staging"
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging", "--dsn", dsn],
      appDir(fixture))
    check result.exitCode == 0
    check result.stdout.contains("restore: writing " & dump & " into bm_staging")
    # The path database is the one pg_restore receives, unchanged.
    check readFile(pgLog).contains("--dbname " & dsn)

  test "a decoy query in the password cannot redirect the write":
    let fixture = newFixture("restore-dsn-password-decoy")
    defer: removeDir(fixture.root)
    let pgLog = fixture.root / "pg_restore.log"
    fixture.installFake("pg_restore",
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " & pgLog & "\nexit 0\n")
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging",
        "--dsn", "postgresql://sachiel:decoy?sslmode=prefer@127.0.0.1:5432/bm_staging?dbname=postgres"],
      appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains(
      "connection parameter 'dbname' in --dsn can change the destination")
    check not fileExists(pgLog)

  test "a semicolon in the query is refused explicitly":
    let fixture = newFixture("restore-dsn-semicolon")
    defer: removeDir(fixture.root)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging",
        "--dsn", "postgres://u@db.example:5432/bm_staging?sslmode=require;dbname=bm2"],
      appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains("--dsn query contains ';'")

  test "a DSN with no query is still accepted":
    let fixture = newFixture("restore-dsn-no-query")
    defer: removeDir(fixture.root)
    fixture.installFake("pg_restore", okFake)
    fixture.installFake("flock", flockFake)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging",
        "--dsn", "postgres://u@db.example:5432/bm_staging"], appDir(fixture))
    check result.exitCode == 0
    check result.stdout.contains("restore: writing " & dump & " into bm_staging")

  test "an IPv6 host is not confused with a query":
    let fixture = newFixture("restore-dsn-ipv6")
    defer: removeDir(fixture.root)
    fixture.installFake("pg_restore", okFake)
    fixture.installFake("flock", flockFake)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging",
        "--dsn", "postgres://u@[::1]:5432/bm_staging"], appDir(fixture))
    check result.exitCode == 0
    check result.stdout.contains("restore: writing " & dump & " into bm_staging")

  test "an authority without a path has no database":
    let fixture = newFixture("restore-dsn-no-path")
    defer: removeDir(fixture.root)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging",
        "--dsn", "postgres://u@db.example:5432"], appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains(
      "restore: cannot read a database name from --dsn")

  test "a query before the path slash cannot smuggle a target into a value":
    let fixture = newFixture("restore-dsn-query-before-path")
    defer: removeDir(fixture.root)
    let pgLog = fixture.root / "pg_restore.log"
    fixture.installFake("pg_restore",
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " & pgLog & "\nexit 0\n")
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    # libpq reads dbname=postgres and treats /bm_staging inside application_name
    # as a value, not a path. The guard must refuse instead of reading it as one.
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging",
        "--dsn", "postgresql://127.0.0.1:5432?dbname=postgres&application_name=/bm_staging"],
      appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains(
      "restore: cannot read a database name from --dsn")
    check not fileExists(pgLog)

  test "a no-path DSN that names the target in dbname is still refused":
    let fixture = newFixture("restore-dsn-no-path-dbname")
    defer: removeDir(fixture.root)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging",
        "--dsn", "postgresql://127.0.0.1:5432?dbname=bm_staging"], appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains(
      "restore: cannot read a database name from --dsn")

  test "an at sign in a query value is not userinfo":
    let fixture = newFixture("restore-dsn-at-in-query")
    defer: removeDir(fixture.root)
    let pgLog = fixture.root / "pg_restore.log"
    fixture.installFake("pg_restore",
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " & pgLog & "\nexit 0\n")
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    # The "@" is inside a query value, so it cannot split userinfo and hide
    # dbname=bm2_prod from the guard.
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging",
        "--dsn", "postgresql:///bm_staging?dbname=bm2_prod&application_name=a@/bm_staging"],
      appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains(
      "connection parameter 'dbname' in --dsn can change the destination")
    check not fileExists(pgLog)

  test "a held deploy lock stops the write before pg_restore":
    let fixture = newFixture("restore-lock-held")
    defer: removeDir(fixture.root)
    fixture.installFake("flock", flockFake)
    let pgLog = fixture.root / "pg_restore.log"
    fixture.installFake("pg_restore",
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " & pgLog & "\nexit 0\n")
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging",
        "--dsn", "postgres://bm2_owner@db.example:5432/bm_staging"],
      appDir(fixture) & @[("FAKE_LOCK_HELD", "1")])
    check result.exitCode == 1
    check result.stderr.contains("another deploy or cutover holds")
    check not fileExists(pgLog)

  test "--recreate keeps the authority and query and drops the database":
    let fixture = newFixture("restore-recreate")
    defer: removeDir(fixture.root)
    fixture.installFake("pg_restore", okFake)
    fixture.installFake("flock", flockFake)
    let log = fixture.root / "psql.log"
    fixture.installFake("psql", psqlLogFake)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let dsn = "postgres://bm2_owner@db.example:5432/bm_staging?sslmode=require"
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging", "--recreate", "--dsn", dsn],
      appDir(fixture) & @[("FAKE_PSQL_LOG", log)])
    check result.exitCode == 0
    let lines = parseLines(readFile(log))
    check lines.len == 1
    # The maintenance connection keeps the authority and the query string, and
    # replaces the target database with `postgres`.
    check lines[0].split(' ')[0] ==
      "postgres://bm2_owner@db.example:5432/postgres?sslmode=require"
    check lines[0].contains("drop database if exists \"bm_staging\" with (force)")
    check lines[0].contains("create database \"bm_staging\"")

  test "--recreate refuses a unix-socket DSN":
    let fixture = newFixture("restore-socket")
    defer: removeDir(fixture.root)
    fixture.installFake("pg_restore", okFake)
    fixture.installFake("flock", flockFake)
    let log = fixture.root / "psql.log"
    fixture.installFake("psql", psqlLogFake)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_restore_x", "--recreate",
        "--dsn", "postgresql:///bm_restore_x"],
      appDir(fixture) & @[("FAKE_PSQL_LOG", log)])
    check result.exitCode == 2
    check result.stderr.contains(
      "restore: --recreate needs a host in --dsn; refusing to drop 'bm_restore_x' on an unknown server")
    check result.stderr.contains(
      "restore: pass --dsn postgres://<user>@<host>:<port>/<database>")
    check not fileExists(log)

  test "restore keeps privileges and only replaces ownership":
    let fixture = newFixture("restore-privileges")
    defer: removeDir(fixture.root)
    let restoreLog = fixture.root / "restore.log"
    fixture.installFake("pg_restore",
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$FAKE_RESTORE_LOG\"\nprintf ''\n")
    fixture.installFake("flock", flockFake)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm2_test",
        "--dsn", "postgres://bm2_owner@db.example:5432/bm2_test"],
      appDir(fixture) & @[("FAKE_RESTORE_LOG", restoreLog)])
    check result.exitCode == 0
    let calls = readFile(restoreLog)
    check calls.contains("--no-owner")
    check not calls.contains("--no-privileges")
    check calls.contains("--dbname postgres://bm2_owner@db.example:5432/bm2_test")

  test "--no-privileges is still available for a staging restore":
    let fixture = newFixture("restore-staging-privs")
    defer: removeDir(fixture.root)
    let restoreLog = fixture.root / "restore.log"
    fixture.installFake("pg_restore",
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$FAKE_RESTORE_LOG\"\nprintf ''\n")
    fixture.installFake("flock", flockFake)
    let dump = fixture.root / "dump.bin"
    touch(dump, "dump")
    let result = fixture.runShell(fixture.installOpsScript("restore.sh"),
      @["--file", dump, "--target", "bm_staging", "--no-privileges",
        "--dsn", "postgres://bm2_owner@db.example:5432/bm_staging"],
      appDir(fixture) & @[("FAKE_RESTORE_LOG", restoreLog)])
    check result.exitCode == 0
    check readFile(restoreLog).contains("--no-privileges")

suite "rotate-log.sh":
  test "every log is renamed with a timestamp and forced mode 600":
    let fixture = newFixture("rotate-rename")
    defer: removeDir(fixture.root)
    let logs = fixture.root / "logs"
    createDir(logs)
    let api = logs / "api.log"
    let worker = logs / "worker.log"
    let other = logs / "notes.txt"
    for path in [api, worker, other]:
      touch(path, "line\n")
      setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupRead,
        fpOthersRead})
    let result = fixture.runShell(fixture.installOpsScript("rotate-log.sh"),
      @[], appDir(fixture) & @[("LOG_DIR", logs)])
    check result.exitCode == 0
    check not fileExists(api)
    check not fileExists(worker)
    check fileExists(other)
    var renamed: seq[string]
    for kind, path in walkDir(logs):
      if kind == pcFile and ".log." in path.extractFilename:
        renamed.add(path.extractFilename)
        check mode600(path)
    renamed.sort()
    check renamed.len == 2
    check renamed[0].startsWith("api.log.")
    check renamed[1].startsWith("worker.log.")
    for name in renamed:
      check name.endsWith(".gz")
      let stamp = name[name.find(".log.") + 5 ..< name.len - len(".gz")]
      check stamp.len == 15 and stamp[8] == '-'
    # A second run touches nothing, because no `*.log` is left.
    let again = fixture.runShell(fixture.installOpsScript("rotate-log.sh"),
      @[], appDir(fixture) & @[("LOG_DIR", logs)])
    check again.exitCode == 0

  # OPS-24: a rename bounds the age of a file, not its size.
  test "a log past MAXSIZE is rotated and gzipped on the next run":
    let fixture = newFixture("rotate-maxsize")
    defer: removeDir(fixture.root)
    let logs = fixture.root / "logs"
    createDir(logs)
    let hot = logs / "deploy.log"
    # 2 MB of 'x' stands in for a burst between two rotations.
    writeFile(hot, repeat('x', 2 * 1024 * 1024))
    let result = fixture.runShell(fixture.installOpsScript("rotate-log.sh"),
      @[], appDir(fixture) & @[("LOG_DIR", logs), ("MAXSIZE", "1M")])
    check result.exitCode == 0
    check result.stderr.contains("past MAXSIZE=1M")
    check not fileExists(hot)
    var gz: seq[string]
    for kind, path in walkDir(logs):
      if kind == pcFile and path.endsWith(".gz"):
        gz.add(path)
        check mode600(path)
    check gz.len == 1
    # Repetitive input compresses; the file survives as a bounded copy rather
    # than the 2 MB burst that was on disk.
    check getFileSize(gz[0]) > 0
    check getFileSize(gz[0]) < 1024 * 1024

  test "expired compressed files are pruned and fresh ones kept":
    let fixture = newFixture("rotate-prune")
    defer: removeDir(fixture.root)
    let logs = fixture.root / "logs"
    createDir(logs)
    let old = logs / "deploy.log.20260101-000000.gz"
    let fresh = logs / "deploy.log.20261109-000000.gz"
    touch(old, "old")
    touch(fresh, "fresh")
    age(old, 30)
    let result = fixture.runShell(fixture.installOpsScript("rotate-log.sh"),
      @[], appDir(fixture) & @[("LOG_DIR", logs), ("KEEP_DAYS", "14")])
    check result.exitCode == 0
    check not fileExists(old)
    check fileExists(fresh)

  test "a volume past the threshold starts the disk alert":
    let fixture = newFixture("rotate-disk-alert")
    defer: removeDir(fixture.root)
    let logs = fixture.root / "logs"
    createDir(logs)
    touch(logs / "api.log", "line\n")
    let systemctlLog = fixture.root / "systemctl.log"
    fixture.installFake("systemctl", """#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"
exit 0
""")
    # Every filesystem is more than 0% full, so the threshold fires without
    # filling a disk in the test.
    let result = fixture.runShell(fixture.installOpsScript("rotate-log.sh"),
      @[], appDir(fixture) & @[("LOG_DIR", logs), ("DISK_MAX_PCT", "0"),
        ("FAKE_SYSTEMCTL_LOG", systemctlLog)])
    check result.exitCode == 0
    check result.stderr.contains("full (threshold 0%)")
    check readFile(systemctlLog).contains("start majadu-alert@disk.service")

  test "a missing log directory exits 0 and is not created":
    let fixture = newFixture("rotate-missing")
    defer: removeDir(fixture.root)
    let logs = fixture.root / "absent-logs"
    let result = fixture.runShell(fixture.installOpsScript("rotate-log.sh"),
      @[], appDir(fixture) & @[("LOG_DIR", logs)])
    check result.exitCode == 0
    check not dirExists(logs)
    check result.stdout.len == 0
    check result.stderr.len == 0

suite "smoke.sh":
  test "all checks pass against a well-behaved API":
    let fixture = newFixture("smoke-pass")
    defer: removeDir(fixture.root)
    fixture.installFake("curl", smokeCurl)
    let result = fixture.runShell(fixture.installOpsScript("smoke.sh"),
      @["http://api.invalid", "2.0.0"], appDir(fixture))
    check result.exitCode == 0
    for line in [
      "ok   /version reports 2.0.0",
      "ok   /healthz is ok",
      "ok   /readyz is 200",
      "ok   /metrics is not public",
      "ok   an unknown share code is 404",
      "ok   /auth/me refuses anonymous callers",
    ]:
      check result.stdout.contains(line)
    check result.stdout.contains(
      "smoke: all checks passed against http://api.invalid")
    check result.stderr.len == 0

  test "a stale /version fails the run":
    let fixture = newFixture("smoke-version")
    defer: removeDir(fixture.root)
    fixture.installFake("curl", smokeCurl)
    let result = fixture.runShell(fixture.installOpsScript("smoke.sh"),
      @["http://api.invalid", "2.0.0"],
      appDir(fixture) & @[("FAKE_CURL_VERSION", "9.9.9")])
    check result.exitCode == 1
    check result.stdout.contains(
      "FAIL /version does not report 2.0.0: {\"version\":\"9.9.9\"}")
    check result.stderr.contains(
      "smoke: 1 check(s) failed against http://api.invalid")

suite "deploy-dispatch.sh":
  test "refs/heads/main runs the production script":
    let fixture = newFixture("dispatch-main")
    defer: removeDir(fixture.root)
    let dispatch = fixture.installOpsScript("deploy-dispatch.sh")
    let calls = fixture.root / "prod.calls"
    writeExecutable(fixture.root / "ops" / "scripts" / "deploy-vps.sh",
      "#!/bin/sh\nprintf '%s\\n' \"$*\" > " & calls & "\n")
    let result = fixture.runShell(dispatch,
      @["badminton-match", "refs/heads/main"], appDir(fixture))
    check result.exitCode == 0
    check readFile(calls).strip == "badminton-match refs/heads/main"

  test "the RC ref runs the RC script only when the env file exists":
    let fixture = newFixture("dispatch-rc")
    defer: removeDir(fixture.root)
    let rcDir = fixture.root / "rc"
    createDir(rcDir)
    let calls = fixture.root / "rc.calls"
    createDir(fixture.root / "rc" / "scripts")
    writeExecutable(rcDir / "scripts" / "deploy-vps-rc.sh",
      "#!/bin/sh\nprintf '%s\\n' \"$*\" > " & calls & "\n")
    let dispatch = fixture.installOpsScript("deploy-dispatch.sh")
    let env = appDir(fixture) & @[("MAJADU_RC_APP_DIR", rcDir)]
    let unBootstrapped = fixture.runShell(dispatch,
      @["badminton-match", "refs/heads/release/2.0.0-rc.1"], env)
    check unBootstrapped.exitCode == 0
    check unBootstrapped.stdout.contains(
      "dispatch: " & rcDir & " is not bootstrapped yet; nothing to deploy")
    check not fileExists(calls)
    touch(rcDir / "env" / "majadu-rc.env", "MAJADU_OWNER_DSN=x\n")
    let bootstrapped = fixture.runShell(dispatch,
      @["badminton-match", "refs/heads/release/2.0.0-rc.1"], env)
    check bootstrapped.exitCode == 0
    check readFile(calls).strip == "badminton-match refs/heads/release/2.0.0-rc.1"

  test "an unrelated ref exits 0 without running either script":
    let fixture = newFixture("dispatch-other")
    defer: removeDir(fixture.root)
    let prodCalls = fixture.root / "prod.calls"
    createDir(fixture.root / "ops" / "scripts")
    writeExecutable(fixture.root / "ops" / "scripts" / "deploy-vps.sh",
      "#!/bin/sh\nprintf '%s\\n' \"$*\" > " & prodCalls & "\n")
    let rcDir = fixture.root / "rc"
    createDir(rcDir / "scripts")
    let rcCalls = fixture.root / "rc.calls"
    touch(rcDir / "env" / "majadu-rc.env", "MAJADU_OWNER_DSN=x\n")
    writeExecutable(rcDir / "scripts" / "deploy-vps-rc.sh",
      "#!/bin/sh\nprintf '%s\\n' \"$*\" > " & rcCalls & "\n")
    let result = fixture.runShell(
      fixture.installOpsScript("deploy-dispatch.sh"),
      @["badminton-match", "refs/heads/dev"],
      appDir(fixture) & @[("MAJADU_RC_APP_DIR", rcDir)])
    check result.exitCode == 0
    check result.stdout.contains(
      "dispatch: ref 'refs/heads/dev' has no target; nothing to deploy")
    check not fileExists(prodCalls)
    check not fileExists(rcCalls)

  test "a routed ref with no target script exits 1":
    let fixture = newFixture("dispatch-missing")
    defer: removeDir(fixture.root)
    let rcDir = fixture.root / "rc"
    touch(rcDir / "env" / "majadu-rc.env", "MAJADU_OWNER_DSN=x\n")
    let result = fixture.runShell(
      fixture.installOpsScript("deploy-dispatch.sh"),
      @["badminton-match", "refs/heads/release/2.0.0-rc.1"],
      appDir(fixture) & @[("MAJADU_RC_APP_DIR", rcDir)])
    check result.exitCode == 1
    check result.stdout.contains("dispatch: " & rcDir & "/scripts/deploy-vps-rc.sh is missing")

const releaseTagCurl = """#!/bin/sh
printf '%s' '{"tag_name":"v2.0.0","body":"digest: sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}'
exit 0
"""

const systemctlLogFake = """#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"
exit 0
"""

const releaseRollbackPodman = """#!/bin/sh
case "$*" in
  "image exists "*) exit 0 ;;
  *"opencontainers.image.version"*) printf '1.9.0\n' ;;
esac
exit 0
"""

const releaseRollbackCurl = """#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    */version) printf '{"version":"1.9.0","commit":"abc"}' ;;
  esac
done
exit 0
"""

suite "release rollback":
  test "a v2 regression returns :prev and rewrites the release state":
    let fixture = newFixture("release-rollback")
    defer: removeDir(fixture.root)
    fixture.installFake("podman", releaseRollbackPodman)
    fixture.installFake("curl", releaseRollbackCurl)
    let log = fixture.root / "systemctl.log"
    fixture.installFake("systemctl", systemctlLogFake)
    let state = fixture.root / "deploy"
    touch(state / "last-release.json",
      "{\"version\":\"2.0.0\",\"commit\":\"new\",\"digest\":\"sha256:" &
      "1111111111111111111111111111111111111111111111111111111111111111\"," &
      "\"schema\":\"0033_new\",\"at\":\"2026-11-09T00:00:00Z\"}\n")
    touch(state / "last-release.json.prev",
      "{\"version\":\"1.9.0\",\"commit\":\"abc\",\"digest\":\"sha256:" &
      "2222222222222222222222222222222222222222222222222222222222222222\"," &
      "\"schema\":\"0032_old\",\"at\":\"2026-11-01T00:00:00Z\"}\n")
    let result = fixture.runShell(
      fixture.installOpsScript("release-rollback.sh"), @[],
      appDir(fixture) & @[("FAKE_SYSTEMCTL_LOG", log)])
    check result.exitCode == 0
    check readFile(state / "deployed-version").strip == "1.9.0"
    check readFile(state / "last-release.json").contains("\"version\":\"1.9.0\"")
    check readFile(state / "last-release.json.rolled-back")
      .contains("\"version\":\"2.0.0\"")
    check readFile(log).contains("restart majadu-api")

  test "a missing :prev is refused and pages":
    let fixture = newFixture("release-rollback-noprev")
    defer: removeDir(fixture.root)
    fixture.installFake("podman", "#!/bin/sh\ncase \"$*\" in \"image exists \"*) exit 1 ;; esac\nexit 0\n")
    let log = fixture.root / "systemctl.log"
    fixture.installFake("systemctl", systemctlLogFake)
    touch(fixture.root / "deploy" / "last-release.json",
      "{\"version\":\"2.0.0\",\"schema\":\"0033_new\"}\n")
    let result = fixture.runShell(
      fixture.installOpsScript("release-rollback.sh"), @[],
      appDir(fixture) & @[("FAKE_SYSTEMCTL_LOG", log)])
    check result.exitCode == 1
    check result.stdout.contains(":prev is missing")
    check readFile(log).contains("start majadu-alert@release-rollback.service")

suite "webhook routing and deploy drift":
  test "the committed webhook definition routes to the dispatcher":
    let body = readFile(repoDir / "ops" / "webhook" / "webhook.json")
    check body.contains("deploy-dispatch.sh")
    check not body.contains("\"execute-command\": \"/srv/qouver/apps/majadu/scripts/deploy-vps.sh\"")

  test "install-webhook --check names a stale execute-command":
    let fixture = newFixture("webhook-check-stale")
    defer: removeDir(fixture.root)
    let target = fixture.root / "config" / "webhook.json"
    touch(target,
      "{\"execute-command\": \"/srv/qouver/apps/majadu/scripts/deploy-vps.sh\"," &
      "\"trigger-rule\": {}}\n")
    let result = fixture.runShell(
      fixture.installOpsScript("install-webhook.sh"),
      @["--check"],
      appDir(fixture) & @[("MAJADU_WEBHOOK_CONFIG", target)])
    check result.exitCode == 1
    check result.stdout.contains("deploy-dispatch.sh")

  test "install-webhook replaces the command and keeps the HMAC secret":
    let fixture = newFixture("webhook-install")
    defer: removeDir(fixture.root)
    let target = fixture.root / "config" / "webhook.json"
    touch(target,
      "{\n  \"execute-command\": \"/srv/qouver/apps/majadu/scripts/deploy-vps.sh\",\n" &
      "  \"command-working-directory\": \"/srv/qouver/apps/majadu\",\n" &
      "  \"trigger-rule\": {\"match\": {\"secret\": \"keep-me\"}}\n}\n")
    let result = fixture.runShell(
      fixture.installOpsScript("install-webhook.sh"), @[],
      appDir(fixture) & @[("MAJADU_WEBHOOK_CONFIG", target)])
    check result.exitCode == 0
    let body = readFile(target)
    check body.contains("deploy-dispatch.sh")
    check body.contains("keep-me")
    check mode600(target)

  test "deploy-check alerts when deployed-version is missing":
    let fixture = newFixture("deploy-check-missing")
    defer: removeDir(fixture.root)
    fixture.installFake("curl", releaseTagCurl)
    let log = fixture.root / "systemctl.log"
    fixture.installFake("systemctl", systemctlLogFake)
    let result = fixture.runShell(
      fixture.installOpsScript("deploy-check.sh"), @[],
      appDir(fixture) & @[("FAKE_SYSTEMCTL_LOG", log)])
    check result.exitCode == 1
    check readFile(log).contains("start majadu-alert@deploy-check.service")

  test "deploy-check is quiet when deployed-version matches":
    let fixture = newFixture("deploy-check-match")
    defer: removeDir(fixture.root)
    fixture.installFake("curl", releaseTagCurl)
    let log = fixture.root / "systemctl.log"
    fixture.installFake("systemctl", systemctlLogFake)
    touch(fixture.root / "deploy" / "deployed-version", "2.0.0\n")
    let result = fixture.runShell(
      fixture.installOpsScript("deploy-check.sh"), @[],
      appDir(fixture) & @[("FAKE_SYSTEMCTL_LOG", log)])
    check result.exitCode == 0
    check result.stdout.contains("matches the latest release")
    check not fileExists(log)
suite "release-preflight.sh":
  test "no tag argument exits 2":
    let fixture = newFixture("preflight-usage")
    defer: removeDir(fixture.root)
    let result = fixture.runShell(
      fixture.installOpsScript("release-preflight.sh"), @[],
      @[("MAJADU_REPO_DIR", fixture.root)])
    check result.exitCode == 2
    check result.stderr.contains("release-preflight.sh v2.0.0-rc.1")

  test "a missing tag is reported with the other missing inputs":
    let fixture = newFixture("preflight-no-tag")
    defer: removeDir(fixture.root)
    let curlLog = fixture.root / "curl.log"
    fixture.installFake("git", "#!/bin/sh\nexit 1\n")
    fixture.installFake("curl", """#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
exit 0
""")
    touch(fixture.root / "VERSION", "2.0.0-rc.1\n")
    let result = fixture.runShell(
      fixture.installOpsScript("release-preflight.sh"), @["v2.0.0-rc.1"],
      @[("MAJADU_REPO_DIR", fixture.root), ("FAKE_CURL_LOG", curlLog)])
    check result.exitCode == 1
    check result.stderr.contains("tag v2.0.0-rc.1 does not exist")
    check result.stderr.contains("cosign is not installed")
    # The lookup still ran so the operator sees every gap in one pass.
    check readFile(curlLog).contains("releases/tags/v2.0.0-rc.1")

  test "a signed tag with one digest and a verifying image passes":
    let fixture = newFixture("preflight-ok")
    defer: removeDir(fixture.root)
    fixture.installFake("git", "#!/bin/sh\nexit 0\n")
    fixture.installFake("curl", """#!/bin/sh
printf '%s' '{"body":"notes\ndigest: sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"}'
exit 0
""")
    fixture.installFake("cosign", "#!/bin/sh\nexit 0\n")
    touch(fixture.root / "VERSION", "2.0.0-rc.1\n")
    for name in ["majadu-prod.env", "majadu-tools.env", "ghcr-token",
                 "cosign.pub"]:
      let path = fixture.root / "env" / name
      touch(path, "x\n")
      setFilePermissions(path, {fpUserRead, fpUserWrite})
    let result = fixture.runShell(
      fixture.installOpsScript("release-preflight.sh"), @["v2.0.0-rc.1"],
      @[("MAJADU_REPO_DIR", fixture.root), ("MAJADU_APP_DIR", fixture.root)])
    check result.exitCode == 0
    check result.stdout.contains("release v2.0.0-rc.1 publishes exactly one digest")
    check result.stdout.contains("verifies with")

  test "a world-readable env file fails the preflight":
    let fixture = newFixture("preflight-env-mode")
    defer: removeDir(fixture.root)
    fixture.installFake("git", "#!/bin/sh\nexit 0\n")
    fixture.installFake("curl", """#!/bin/sh
printf '%s' '{"body":"digest: sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"}'
exit 0
""")
    fixture.installFake("cosign", "#!/bin/sh\nexit 0\n")
    touch(fixture.root / "VERSION", "2.0.0-rc.1\n")
    for name in ["majadu-tools.env", "ghcr-token", "cosign.pub"]:
      let path = fixture.root / "env" / name
      touch(path, "x\n")
      setFilePermissions(path, {fpUserRead, fpUserWrite})
    let prod = fixture.root / "env" / "majadu-prod.env"
    touch(prod, "x\n")
    setFilePermissions(prod, {fpUserRead, fpUserWrite, fpGroupRead,
      fpOthersRead})
    let result = fixture.runShell(
      fixture.installOpsScript("release-preflight.sh"), @["v2.0.0-rc.1"],
      @[("MAJADU_REPO_DIR", fixture.root), ("MAJADU_APP_DIR", fixture.root)])
    check result.exitCode == 1
    check result.stderr.contains(prod & " must be mode 600 (found 644)")

suite "audit-digest.sh":
  test "a missing DSN exits 2 without touching the backup directory":
    let fixture = newFixture("audit-digest-no-dsn")
    defer: removeDir(fixture.root)
    let result = fixture.runShell(
      fixture.installOpsScript("audit-digest.sh"), @[],
      @[("MAJADU_APP_DIR", fixture.root)])
    check result.exitCode == 2
    check result.stderr.contains("MAJADU_AUDIT_DSN is not set")

  test "the digest is written atomically and stays private":
    let fixture = newFixture("audit-digest-ok")
    defer: removeDir(fixture.root)
    fixture.installFake("psql", """#!/bin/sh
printf '42:deadbeef\n'
exit 0
""")
    let backups = fixture.root / "backups"
    let result = fixture.runShell(
      fixture.installOpsScript("audit-digest.sh"), @[],
      @[("MAJADU_APP_DIR", fixture.root),
        ("MAJADU_BACKUP_DIR", backups),
        ("MAJADU_AUDIT_DSN", "postgres://bm2_audit_prune@127.0.0.1:5432/bm2")])
    check result.exitCode == 0
    var digestFiles: seq[string]
    for kind, path in walkDir(backups):
      if kind == pcFile and path.extractFilename.startsWith("audit-digest-"):
        digestFiles.add(path)
    check digestFiles.len == 1
    let body = readFile(digestFiles[0])
    check body.contains("\"rows\":42")
    check body.contains("\"digest\":\"deadbeef\"")
    check mode600(digestFiles[0])
    for kind, path in walkDir(backups):
      check not path.extractFilename.contains(".tmp")

  test "an answer that is not a count exits 1":
    let fixture = newFixture("audit-digest-bad")
    defer: removeDir(fixture.root)
    fixture.installFake("psql", """#!/bin/sh
printf 'ERROR: permission denied for table audit\n'
exit 0
""")
    let result = fixture.runShell(
      fixture.installOpsScript("audit-digest.sh"), @[],
      @[("MAJADU_APP_DIR", fixture.root),
        ("MAJADU_BACKUP_DIR", fixture.root / "backups"),
        ("MAJADU_AUDIT_DSN", "postgres://bm2_audit_prune@127.0.0.1:5432/bm2")])
    check result.exitCode == 1
    check result.stderr.contains("unexpected answer")

suite "single log destination":
  test "no API unit mounts a log volume":
    for unit in ["majadu-api.container", "majadu-rc-api.container"]:
      let text = readFile(repoDir / "ops" / "systemd" / unit)
      check not text.contains(":/logs")
      check not text.contains("/logs:")

suite "host-check.sh":
  test "a full volume pages through the disk alert":
    let fixture = newFixture("host-check-disk")
    defer: removeDir(fixture.root)
    fixture.installFake("systemctl", """#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"
exit 0
""")
    let systemctlLog = fixture.root / "systemctl.log"
    let result = fixture.runShell(fixture.installOpsScript("host-check.sh"),
      @[], @[("MAJADU_APP_DIR", fixture.root), ("MIN_FREE_MB", "999999999"),
        ("FAKE_SYSTEMCTL_LOG", systemctlLog)])
    check result.exitCode == 1
    check result.stdout.contains("below 999999999 MB")
    check readFile(systemctlLog).contains("start majadu-alert@disk.service")

  test "an OOM-killed container pages through the memory alert":
    let fixture = newFixture("host-check-oom")
    defer: removeDir(fixture.root)
    fixture.installFake("systemctl", """#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"
exit 0
""")
    fixture.installFake("podman", """#!/bin/sh
case "$*" in
  *OOMKilled*) printf 'true\n' ;;
  *"image exists"*) exit 1 ;;
esac
exit 0
""")
    let systemctlLog = fixture.root / "systemctl.log"
    let result = fixture.runShell(fixture.installOpsScript("host-check.sh"),
      @[], @[("MAJADU_APP_DIR", fixture.root), ("MIN_FREE_MB", "0"),
        ("FAKE_SYSTEMCTL_LOG", systemctlLog)])
    check result.exitCode == 1
    check result.stdout.contains("was OOM-killed")
    check readFile(systemctlLog).contains("start majadu-alert@memory.service")

  test "a healthy host is quiet":
    let fixture = newFixture("host-check-ok")
    defer: removeDir(fixture.root)
    fixture.installFake("systemctl", "#!/bin/sh\nexit 0\n")
    fixture.installFake("podman", "#!/bin/sh\nexit 1\n")
    let result = fixture.runShell(fixture.installOpsScript("host-check.sh"),
      @[], @[("MAJADU_APP_DIR", fixture.root), ("MIN_FREE_MB", "0")])
    check result.exitCode == 0
    check result.stdout.contains("ok:")
