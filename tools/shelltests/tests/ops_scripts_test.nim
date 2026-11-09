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
      let stamp = name[name.rfind('.') + 1 .. ^1]
      check stamp.len == 15 and stamp[8] == '-'
    # A second run touches nothing, because no `*.log` is left.
    let again = fixture.runShell(fixture.installOpsScript("rotate-log.sh"),
      @[], appDir(fixture) & @[("LOG_DIR", logs)])
    check again.exitCode == 0

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