# TL-20: the deploy and rollback guards (`deploy-vps.sh`, `cutover.sh`,
# `rollback.sh`, `release-rollback.sh`).
#
# Every case points `MAJADU_APP_DIR` at a temp directory and answers the process
# edges with fakes on the fixture PATH (`podman`, `psql`, `curl`, `flock`,
# `git`). No case reaches `/srv`, a database or a host.
#
# The RC pair (`deploy-vps-rc.sh`, `bootstrap-rc.sh`) and their cases went with
# the instance itself on 2026-11-21.
#
# The guards are all reached before the first real side effect, so each case
# stops inside the guard it names instead of deploys.

import std/[json, os, strutils, unittest]
import ../harness

const okFake = """#!/bin/sh
exit 0
"""

# A health endpoint that never answers: the state a container that exits before
# READY leaves behind.
const deadCurlFake = """#!/bin/sh
exit 7
"""

const podmanFake = """#!/bin/sh
if [ -n "${FAKE_PODMAN_LOG:-}" ]; then
  printf '%s\n' "$*" >>"$FAKE_PODMAN_LOG"
fi
case "$*" in
  "image exists "*) exit "${FAKE_PODMAN_IMAGE_EXISTS:-0}" ;;
  *"State.Running"*) printf '%s\n' "${FAKE_CONTAINER_RUNNING:-false}" ; exit 0 ;;
  *"{{.Id}}"*) printf 'sha256:%s\n' "${FAKE_IMAGE_ID:-1111111111111111111111111111111111111111111111111111111111111111}" ; exit 0 ;;
  *"{{.Digest}}"*) printf 'sha256:%s\n' "${FAKE_IMAGE_DIGEST:-2222222222222222222222222222222222222222222222222222222222222222}" ; exit 0 ;;
  *"migrate --dir /app/db/migrations"*) exit "${FAKE_MIGRATE_EXIT:-0}" ;;
  *"datname = 'bm2'"*) printf '%s\n' "${FAKE_BM2_EXISTS:-}" ; exit 0 ;;
  *org.opencontainers.image.revision*) printf '%s\n' "${FAKE_IMAGE_REV:-abc1234}" ; exit 0 ;;
esac
exit 0
"""

const psqlFake = """#!/bin/sh
if [ -n "${FAKE_PSQL_LOG:-}" ]; then
  printf '%s\n' "$*" >>"$FAKE_PSQL_LOG"
fi
case "$*" in
  *"platform.cutover_state c"*) printf '%s\n' "${FAKE_ABANDONED:-}" ; exit 0 ;;
esac
exit 0
"""

const gitFake = """#!/bin/sh
case "$*" in
  *"rev-parse HEAD"*) printf 'abc1234\n' ;;
  # The deploy migrates only for a commit a release tag points at; both the tag
  # object and its peeled commit are listed, as `git ls-remote --tags` does.
  *"ls-remote --tags origin"*) printf 'abc1234\trefs/tags/v2.0.0\nabc1234\trefs/tags/v2.0.0^{}\n' ;;
esac
exit 0
"""

# A hotfix reaches main without a tag, so `ls-remote` answers with no tag at all.
const gitFakeNoRelease = """#!/bin/sh
case "$*" in
  *"rev-parse HEAD"*) printf 'abc1234\n' ;;
esac
exit 0
"""

# The release API for the cutover path, which still resolves the digest from the
# published release body. Every other URL is a health probe: exit 0 is enough.
const releaseCurlFake = """#!/bin/sh
case "$*" in
  *api.github.com*) printf '%s' '{"body":"release notes\ndigest: sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"}' ;;
esac
exit 0
"""

const systemctlLogFake = """#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"
exit 0
"""

proc touch(path: string, body = "") =
  createDir(path.parentDir)
  writeFile(path, body)

proc activeAssignment(body, key: string): bool =
  ## Mirrors the deploy gates: leading whitespace, an `export` prefix and
  ## whitespace around `=` are accepted; a commented line is not an assignment.
  for line in body.splitLines:
    var s = line.strip
    if s.len == 0 or s.startsWith("#"):
      continue
    if s.startsWith("export") and s.len > 6 and s[6] in {' ', '\t'}:
      s = s[6 .. ^1].strip
    if s.startsWith(key) and s.len > key.len:
      if s[key.len .. ^1].strip.startsWith("="):
        return true
  false

proc appDir(fixture: Fixture, dir: string = ""): seq[(string, string)] =
  @[("MAJADU_APP_DIR", if dir.len > 0: dir else: fixture.root)]

proc privateFile(path, body: string) =
  touch(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite})

proc installRolesSql(fixture: Fixture) =
  ## cutover.sh hands roles.sql to psql over stdin, so the fixture needs the file
  ## where the script resolves it: $MAJADU_APP_DIR/monorepo/ops/db/roles.sql.
  ## A missing file fails the redirect inside bash, before psql is ever called.
  let dest = fixture.root / "monorepo" / "ops" / "db" / "roles.sql"
  createDir(dest.parentDir)
  copyFile(repoDir / "ops" / "db" / "roles.sql", dest)

# The tool env is the only env file the one-shot job units load, so every
# fixture that reaches past the split gate has to carry the application DSN.
const toolsEnvBody =
  "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n" &
  "MAJADU_OWNER_DSN=postgres://bm2_owner@127.0.0.1:5432/bm2\n"

proc simFakes(fixture: Fixture) =
  ## The process edges a simulated deploy needs: no lock contention, a green
  ## health endpoint, a podman that answers `image exists` and a psql that logs.
  fixture.installFake("flock", okFake)
  fixture.installFake("curl", okFake)
  fixture.installFake("podman", podmanFake)
  fixture.installFake("psql", psqlFake)
  fixture.installFake("cosign", okFake)
  # deploy-vps.sh verifies the image signature after it pulls, so every fixture
  # that reaches the pull needs the public key installed.
  privateFile(fixture.root / "env" / "cosign.pub", "fake cosign public key\n")

proc runDeployForEnvGate(fixture: Fixture, apiBody: string,
    extra: seq[(string, string)] = @[]): ShellResult =
  ## Runs the production deploy far enough to reach the API-env gate, with the
  ## checkout, the tool env and a VERSION so the commented-line case can pass
  ## the gate and fail later in the image step.
  simFakes(fixture)
  fixture.installFake("git", gitFake)
  createDir(fixture.root / "monorepo")
  touch(fixture.root / "monorepo" / "VERSION", "2.0.0\n")
  privateFile(fixture.root / "env" / "majadu-prod.env", apiBody)
  privateFile(fixture.root / "env" / "majadu-tools.env", toolsEnvBody)
  # A non-empty token file keeps bash 3.2 from tripping on an empty AUTH array
  # when the commented-line case reaches the registry login.
  privateFile(fixture.root / "env" / "ghcr-token", "fake-token\n")
  fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
    @["badminton-match", "refs/heads/main"],
    appDir(fixture) & @[("MAJADU_SKIP_GIT_SYNC", "1")] & extra)

suite "deploy-vps.sh":
  test "an empty ref is ignored before git or podman":
    let fixture = newFixture("deploy-empty-ref")
    defer: removeDir(fixture.root)
    let podmanLog = fixture.root / "podman.log"
    simFakes(fixture)
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", ""], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
        ("FAKE_PODMAN_LOG", podmanLog),
      ])
    check result.exitCode == 0
    check result.stdout.contains(
      "deploy ignored: ref '<empty>' is not refs/heads/main")
    check not result.stdout.contains("deploy trigger")
    check not fileExists(podmanLog)

  test "a release-branch ref is ignored before git or podman":
    let fixture = newFixture("deploy-other-ref")
    defer: removeDir(fixture.root)
    let podmanLog = fixture.root / "podman.log"
    simFakes(fixture)
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/release/9.9.9"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
        ("FAKE_PODMAN_LOG", podmanLog),
      ])
    check result.exitCode == 0
    check result.stdout.contains(
      "deploy ignored: ref 'refs/heads/release/9.9.9' is not refs/heads/main")
    check not result.stdout.contains("deploy trigger")
    check not fileExists(podmanLog)

  test "a foreign repository is ignored on the main ref":
    let fixture = newFixture("deploy-foreign-repo")
    defer: removeDir(fixture.root)
    let podmanLog = fixture.root / "podman.log"
    simFakes(fixture)
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["someone/fork", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
        ("FAKE_PODMAN_LOG", podmanLog),
      ])
    check result.exitCode == 0
    check result.stdout.contains(
      "deploy ignored: repository 'someone/fork' is not badminton-match")
    check not result.stdout.contains("deploy trigger")
    check not fileExists(podmanLog)

  # BM-08: the lock waited 1200 s and the line that reported the timeout said
  # 900 s, so a reader of the log was given a shorter wait than the script
  # performed. The number in the message has to be the number it waited.
  test "the deploy lock timeout reports the wait it actually used":
    let fixture = newFixture("deploy-lock-timeout")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    fixture.installFake("flock", "#!/bin/sh\nexit 1\n")
    touch(fixture.root / "monorepo" / "VERSION", "2.0.0\n")
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
      ])
    check result.exitCode == 1
    check result.stdout.contains("another deploy still holds the lock after 1200s")
    let lockWait = readFile(opsScriptsDir / "deploy-vps.sh")
    check lockWait.contains("flock -w \"$DEPLOY_LOCK_WAIT\" 9")

  test "a failed restart is a warning, and the readiness gate decides":
    let fixture = newFixture("deploy-restart-warning")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    # The container never becomes ready, which is the state a crash-looping unit
    # produces; the restart's own exit code is what the gate must stop deciding.
    fixture.installFake("curl", deadCurlFake)
    let systemctlLog = fixture.root / "systemctl.log"
    fixture.installFake("systemctl", systemctlLogFake)
    let mono = fixture.root / "monorepo"
    touch(mono / "VERSION", "2.0.0\n")
    touch(mono / "db" / "migrations" / "0001_init.sql", "select 1;\n")
    createDir(mono / "ops" / "systemd")
    createDir(mono / "ops" / "scripts")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env", toolsEnvBody)
    # A token file keeps AUTH non-empty (bash 3.2 treats "${AUTH[@]}" on an
    # empty array as unbound under set -u) and the podman fake answers login.
    privateFile(fixture.root / "env" / "ghcr-token", "fake-token\n")
    # A successful release is already recorded; the failed attempt must leave it
    # intact and write its own record beside it.
    touch(fixture.root / "deploy" / "last-release.json",
      "{\"version\":\"1.9.0\",\"commit\":\"abc\",\"digest\":\"sha256:" &
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"," &
      "\"schema\":\"0031_old\",\"at\":\"2026-10-01T00:00:00Z\"}\n")
    # `false` stands in for a systemctl that refuses both restarts: the forward
    # one and the one inside the rollback. Restart-guard v1.1 rule 8 says neither
    # may decide the deploy, so the script has to reach the readiness gate, log
    # both warnings and let the gate record the failure.
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
        ("MAJADU_SERVICE_CMD", "false"),
        ("FAKE_SYSTEMCTL_LOG", systemctlLog),
      ])
    check result.exitCode != 0
    let deployLog = readFile(fixture.root / "logs" / "deploy.log")
    check deployLog.contains("WARNING: restart majadu-api returned non-zero")
    check deployLog.contains("readiness gate failed")
    check deployLog.contains("WARNING: ROLLBACK restart majadu-api returned non-zero")
    check deployLog.contains("ERROR: readiness gate failed for v")
    # The record names the gate, not the restart: the restart is no longer the
    # step that failed.
    let attempt = parseFile(fixture.root / "deploy" / "last-attempt.json")
    check attempt["step"].getStr == "readiness"
    check attempt["version"].getStr == "1.9.0"
    check readFile(fixture.root / "deploy" / "last-release.json")
      .contains("\"version\":\"1.9.0\"")
    check readFile(fixture.root / "deploy" / "last-release.json")
      .contains("\"schema\":\"0031_old\"")
    check readFile(systemctlLog).contains("start majadu-alert@deploy.service")
    # OPS-23: the failure record is one atomic rename, so it always parses and
    # never leaves a temp file behind for the next deploy to trip over.
    for kind, path in walkDir(fixture.root / "deploy"):
      check not path.extractFilename.contains(".tmp")

  # DB-06: the production deploy migrated and verified but never seeded, while
  # the RC path seeded on every deploy. A registry key with no row is a container
  # that boots and cannot answer, so the seed belongs next to the migration:
  # after `migrate`, before `verify` reads the ledger back.
  test "the deploy seeds between the migration and the schema check":
    let fixture = newFixture("deploy-seed")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    fixture.installFake("systemctl", systemctlLogFake)
    let podmanLog = fixture.root / "podman.log"
    let mono = fixture.root / "monorepo"
    touch(mono / "VERSION", "2.0.0\n")
    touch(mono / "db" / "migrations" / "0001_init.sql", "select 1;\n")
    createDir(mono / "ops" / "systemd")
    createDir(mono / "ops" / "scripts")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env", toolsEnvBody)
    privateFile(fixture.root / "env" / "ghcr-token", "fake-token\n")
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
        ("FAKE_PODMAN_LOG", podmanLog),
      ])
    let calls = readFile(podmanLog)
    let migrateAt = calls.find("migrate --dir /app/db/migrations")
    let verifyAt = calls.find("verify --dir /app/db/migrations")
    let seedAt = calls.find("seed --dir /app/db/seeds")
    check migrateAt >= 0
    check seedAt > migrateAt
    check verifyAt > seedAt
    check readFile(fixture.root / "logs" / "deploy.log").contains("applied the seed files")
    # The fixture stops later in the pipeline (health and smoke probes under
    # fakes); what this case proves is that the seed ran, and that a failure was
    # not the seed step.
    let attempt = fixture.root / "deploy" / "last-attempt.json"
    if fileExists(attempt):
      check parseFile(attempt)["step"].getStr != "seed"

  test "an owner DSN left in the API env stops the deploy":
    let fixture = newFixture("deploy-api-env-owner")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    createDir(fixture.root / "monorepo")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n" &
      "MAJADU_OWNER_DSN=postgres://bm2_owner@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env", toolsEnvBody)
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
      ])
    check result.exitCode == 1
    let envFile = fixture.root / "env" / "majadu-prod.env"
    let toolsFile = fixture.root / "env" / "majadu-tools.env"
    check result.stdout.contains(
      envFile & ":2 must not contain MAJADU_OWNER_DSN; move it to " & toolsFile)
    check readFile(fixture.root / "deploy" / "last-attempt.json")
      .contains("\"step\":\"env-split\"")

  # OPS-05: the job units load majadu-tools.env as their only env file, so the
  # deploy has to prove the file can actually run them before installing units
  # that would fail on every tick.
  test "a tool env without the application DSN stops the deploy":
    let fixture = newFixture("deploy-tool-env-no-app-dsn")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    createDir(fixture.root / "monorepo")
    touch(fixture.root / "monorepo" / "VERSION", "2.0.0\n")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env",
      "MAJADU_OWNER_DSN=postgres://bm2_owner@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "ghcr-token", "fake-token\n")
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
      ])
    check result.exitCode == 1
    check result.stdout.contains(
      (fixture.root / "env" / "majadu-tools.env") &
      " must define MAJADU_PG_DSN for the job units")
    check readFile(fixture.root / "deploy" / "last-attempt.json")
      .contains("\"step\":\"env-split\"")

  test "a share-code keyring in the tool env stops the deploy":
    let fixture = newFixture("deploy-tool-env-keyring")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    createDir(fixture.root / "monorepo")
    touch(fixture.root / "monorepo" / "VERSION", "2.0.0\n")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env",
      toolsEnvBody & "SHARE_CODE_KEYS={\"1\":\"secret\"}\n")
    privateFile(fixture.root / "env" / "ghcr-token", "fake-token\n")
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
      ])
    check result.exitCode == 1
    check result.stdout.contains(
      (fixture.root / "env" / "majadu-tools.env") &
      ":3 must not contain SHARE_CODE_KEYS")

  # OPS-05: a 0755 env directory leaks the credential file names even when every
  # file inside it is 600, so the deploy fixes the directory and refuses to run
  # one owned by someone else.
  test "the env directory is mode 700 after the split gate":
    let fixture = newFixture("deploy-env-dir-mode")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    createDir(fixture.root / "monorepo")
    touch(fixture.root / "monorepo" / "VERSION", "2.0.0\n")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env", toolsEnvBody)
    privateFile(fixture.root / "env" / "ghcr-token", "fake-token\n")
    setFilePermissions(fixture.root / "env",
      {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
       fpOthersRead, fpOthersExec})
    discard fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
      ])
    let envPerms = getFilePermissions(fixture.root / "env")
    check fpUserExec in envPerms
    check fpGroupRead notin envPerms
    check fpGroupExec notin envPerms
    check fpOthersRead notin envPerms
    check fpOthersExec notin envPerms
  test "the deploy log and state files are private from the first byte":
    let fixture = newFixture("deploy-log-mode")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    createDir(fixture.root / "monorepo")
    touch(fixture.root / "monorepo" / "VERSION", "2.0.0\n")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    # A log left behind by an older deploy is 0644; the next run has to fix it
    # instead of appending to it.
    touch(fixture.root / "logs" / "deploy.log", "old line\n")
    setFilePermissions(fixture.root / "logs" / "deploy.log",
      {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
      ])
    check result.exitCode == 1
    let logPerms = getFilePermissions(fixture.root / "logs" / "deploy.log")
    check fpGroupRead notin logPerms
    check fpOthersRead notin logPerms
    let statePerms = getFilePermissions(
      fixture.root / "deploy" / "last-attempt.json")
    check fpGroupRead notin statePerms
    check fpOthersRead notin statePerms
    let logDir = getFilePermissions(fixture.root / "logs")
    check fpGroupRead notin logDir
    check fpOthersRead notin logDir

  # OPS-22: the "already live" gate trusted deployed-version alone, which is why
  # a hotfix that did not bump VERSION never deployed. The gate is the commit,
  # and the running container has to carry that commit's revision label.
  test "a matching deployed-rev with a running service is a no-op":
    let fixture = newFixture("deploy-live-ok")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    createDir(fixture.root / "monorepo")
    touch(fixture.root / "monorepo" / "VERSION", "2.0.0\n")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env", toolsEnvBody)
    touch(fixture.root / "deploy" / "deployed-rev", "abc1234\n")
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
        ("FAKE_CONTAINER_RUNNING", "true"),
        ("FAKE_IMAGE_REV", "abc1234"),
      ])
    check result.exitCode == 0
    check result.stdout.contains("commit abc1234 is already live; nothing to do")

  test "a deleted :local defeats the deployed-rev short-circuit":
    let fixture = newFixture("deploy-live-no-image")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    createDir(fixture.root / "monorepo")
    touch(fixture.root / "monorepo" / "VERSION", "2.0.0\n")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env", toolsEnvBody)
    touch(fixture.root / "deploy" / "deployed-rev", "abc1234\n")
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
        ("FAKE_CONTAINER_RUNNING", "true"),
        ("FAKE_PODMAN_IMAGE_EXISTS", "1"),
      ])
    check result.stdout.contains(
      "abc1234 is recorded as live but localhost/majadu-api:local is missing")
    check not result.stdout.contains("nothing to do")

  test "a stopped container defeats the deployed-rev short-circuit":
    let fixture = newFixture("deploy-live-stopped")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    createDir(fixture.root / "monorepo")
    touch(fixture.root / "monorepo" / "VERSION", "2.0.0\n")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env", toolsEnvBody)
    touch(fixture.root / "deploy" / "deployed-rev", "abc1234\n")
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
        ("FAKE_CONTAINER_RUNNING", "false"),
      ])
    check result.stdout.contains(
      "abc1234 is recorded as live but container majadu-api is not running")
    check not result.stdout.contains("nothing to do")

  test "a container without this commit's revision defeats the short-circuit":
    # The state file says the commit is live, but a container built from another
    # commit is still running it: the label the image job stamps is the proof.
    let fixture = newFixture("deploy-live-wrong-rev")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    createDir(fixture.root / "monorepo")
    touch(fixture.root / "monorepo" / "VERSION", "2.0.0\n")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env", toolsEnvBody)
    touch(fixture.root / "deploy" / "deployed-rev", "abc1234\n")
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
        ("FAKE_CONTAINER_RUNNING", "true"),
        ("FAKE_IMAGE_REV", "9999999"),
      ])
    check result.stdout.contains(
      "abc1234 is recorded as live but majadu-api does not carry revision abc1234")
    check not result.stdout.contains("nothing to do")

  # OPS-17: the GHCR token used to be built into a curl argument, where any
  # process of the same user reads it with `ps -ef`. It reaches the registry on
  # stdin to `podman login`, and no argv of any process may carry it.
  test "the registry token never reaches argv":
    let fixture = newFixture("deploy-token-argv")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    let podmanLog = fixture.root / "podman.log"
    # Stop right after the pull: a failing cosign keeps the case about argv.
    fixture.installFake("cosign", "#!/bin/sh\nexit 1\n")
    createDir(fixture.root / "monorepo")
    touch(fixture.root / "monorepo" / "VERSION", "2.0.0\n")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env", toolsEnvBody)
    privateFile(fixture.root / "env" / "ghcr-token", "secret-token\n")
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
        ("FAKE_PODMAN_LOG", podmanLog),
      ])
    check result.exitCode == 1
    check result.stdout.contains("cosign verify failed")
    let argv = readFile(podmanLog)
    check argv.contains("login ghcr.io")
    check argv.contains("--password-stdin")
    check not argv.contains("secret-token")
    check not readFile(fixture.root / "logs" / "deploy.log").contains("secret-token")

  # OPS-24: the image job pushes the tag and signs the digest in two steps. A
  # deploy that pulled in between used to fail 3 seconds later with "no
  # signatures found" and leave production on the previous commit, which is
  # exactly what happened on 2026-11-16 at a65ef1a. The wait is for that answer
  # only, so the case below pairs with the wrong-signature one.
  test "a signature that lands after the pull is waited for":
    let fixture = newFixture("deploy-sign-late")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    let state = fixture.root / "cosign.signed"
    fixture.installFake("cosign", "#!/bin/sh\n" &
      "if [ -f '" & state & "' ]; then exit 0; fi\n" &
      ": >'" & state & "'\n" &
      "echo 'Error: no signatures found' >&2\n" &
      "exit 1\n")
    let sleepLog = fixture.root / "sleep.log"
    fixture.installFake("sleep", "#!/bin/sh\necho \"sleep $*\" >>'" & sleepLog & "'\nexit 0\n")
    createDir(fixture.root / "monorepo")
    touch(fixture.root / "monorepo" / "VERSION", "2.0.0\n")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env", toolsEnvBody)
    privateFile(fixture.root / "env" / "ghcr-token", "fake-token\n")
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
      ])
    let deployLog = readFile(fixture.root / "logs" / "deploy.log")
    check deployLog.contains("is not signed yet; the image job is still signing it (attempt 1 of 18)")
    check deployLog.contains("verified at revision")
    check readFile(sleepLog).contains("sleep 10")
    check not result.stdout.contains("cosign verify failed")

  test "a wrong signature fails on the first attempt":
    # A tampered digest or a foreign key is not a race: waiting cannot fix it,
    # and a retry loop that swallowed it would turn a failed deploy into a slow
    # one.
    let fixture = newFixture("deploy-sign-wrong")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    fixture.installFake("cosign",
      "#!/bin/sh\necho 'Error: verifying signature: invalid signature' >&2\nexit 1\n")
    let sleepLog = fixture.root / "sleep.log"
    fixture.installFake("sleep", "#!/bin/sh\necho \"sleep $*\" >>'" & sleepLog & "'\nexit 0\n")
    createDir(fixture.root / "monorepo")
    touch(fixture.root / "monorepo" / "VERSION", "2.0.0\n")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env", toolsEnvBody)
    privateFile(fixture.root / "env" / "ghcr-token", "fake-token\n")
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
      ])
    check result.exitCode == 1
    check result.stdout.contains("cosign verify failed")
    check not fileExists(sleepLog)

  test "a world-readable credential file fails the deploy":
    let fixture = newFixture("deploy-env-mode")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    createDir(fixture.root / "monorepo")
    touch(fixture.root / "monorepo" / "VERSION", "2.0.0\n")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env", toolsEnvBody)
    privateFile(fixture.root / "env" / "ghcr-token", "fake-token\n")
    touch(fixture.root / "env" / "alert.env", "MAJADU_ALERT_WEBHOOK=x\n")
    setFilePermissions(fixture.root / "env" / "alert.env",
      {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
    let alertFile = fixture.root / "env" / "alert.env"
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
      ])
    check result.exitCode == 1
    check result.stdout.contains(alertFile & " must be mode 600 (found 644)")

  test "a private env reached through a symlink passes the gate":
    # The cutover points majadu-prod.env at a versioned file, and a symlink is
    # always mode 777. The gate has to judge the file it points at, or every
    # deploy after the cutover dies on a 600 env it cannot see.
    let fixture = newFixture("deploy-env-symlink")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    createDir(fixture.root / "monorepo")
    touch(fixture.root / "monorepo" / "VERSION", "2.0.0\n")
    privateFile(fixture.root / "env" / "majadu-prod.env.v2",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    createSymlink(fixture.root / "env" / "majadu-prod.env.v2",
      fixture.root / "env" / "majadu-prod.env")
    privateFile(fixture.root / "env" / "majadu-tools.env", toolsEnvBody)
    privateFile(fixture.root / "env" / "ghcr-token", "fake-token\n")
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
      ])
    check not result.stdout.contains("must be mode 600")
    check result.stdout.contains(
      "pulled ghcr.io/hidaydev/badminton-match:sha-abc1234")

  test "a missing tool env fails before the release lookup":
    let fixture = newFixture("deploy-tool-env-missing")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    createDir(fixture.root / "monorepo")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
      ])
    check result.exitCode == 1
    let toolsFile = fixture.root / "env" / "majadu-tools.env"
    check result.stdout.contains(
      "tool env file " & toolsFile & " is missing; copy ops/env/prod-tools.env.example")
    check not result.stdout.contains("pulled ")

  test "the prod env gate sees systemd assignment forms":
    let cases = [
      ("leading-space", " MAJADU_OWNER_DSN=postgres://bm2_owner@127.0.0.1:5432/bm2"),
      ("leading-tab", "\tMAJADU_OWNER_DSN=postgres://bm2_owner@127.0.0.1:5432/bm2"),
      ("space-before-equals", "MAJADU_OWNER_DSN =postgres://bm2_owner@127.0.0.1:5432/bm2"),
      ("export-prefix", "export MAJADU_OWNER_DSN=postgres://bm2_owner@127.0.0.1:5432/bm2"),
    ]
    for (label, line) in cases:
      let fixture = newFixture("deploy-gate-" & label)
      let podmanLog = fixture.root / "podman.log"
      let result = runDeployForEnvGate(fixture,
        "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n" & line & "\n",
        @[("FAKE_PODMAN_LOG", podmanLog)])
      check result.exitCode == 1
      check result.stdout.contains(":2 must not contain MAJADU_OWNER_DSN")
      check result.stdout.contains("move it to " &
        (fixture.root / "env" / "majadu-tools.env"))
      check not fileExists(podmanLog)
      check not fileExists(fixture.root / "home" / ".config" / "systemd" /
        "user" / "majadu-api.container")
      removeDir(fixture.root)

  test "a commented tool DSN does not trip the prod env gate":
    let fixture = newFixture("deploy-gate-comment")
    defer: removeDir(fixture.root)
    let result = runDeployForEnvGate(fixture,
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n" &
      "# MAJADU_OWNER_DSN=postgres://bm2_owner@127.0.0.1:5432/bm2\n")
    check not result.stdout.contains("must not contain MAJADU_OWNER_DSN")
    check result.stdout.contains(
      "pulled ghcr.io/hidaydev/badminton-match:sha-abc1234")

  test "a pre-cutover host exits 0 without the tool env":
    let fixture = newFixture("deploy-pre-cutover")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    createDir(fixture.root / "monorepo")
    touch(fixture.root / "monorepo" / "VERSION", "2.0.0\n")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm\n")
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
      ])
    check result.exitCode == 0
    check result.stdout.contains(
      "production does not point at bm2 yet: cutover has not happened, nothing to deploy")
    check not result.stdout.contains("tool env file")

  # OPS-21: a hotfix lands on main without a release tag. It gets the image and
  # the container, but the schema is verified rather than migrated, so a hotfix
  # that brought a migration is refused by that verify instead of applied.
  test "a commit without a release tag verifies the schema without migrating":
    let fixture = newFixture("deploy-hotfix-no-tag")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFakeNoRelease)
    fixture.installFake("systemctl", systemctlLogFake)
    let podmanLog = fixture.root / "podman.log"
    let mono = fixture.root / "monorepo"
    touch(mono / "VERSION", "2.0.0\n")
    touch(mono / "db" / "migrations" / "0001_init.sql", "select 1;\n")
    createDir(mono / "ops" / "systemd")
    createDir(mono / "ops" / "scripts")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env", toolsEnvBody)
    privateFile(fixture.root / "env" / "ghcr-token", "fake-token\n")
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
        ("FAKE_PODMAN_LOG", podmanLog),
      ])
    let calls = readFile(podmanLog)
    check result.stdout.contains(
      "commit abc1234 carries no release tag; the schema is verified, not migrated")
    check calls.contains("pull ghcr.io/hidaydev/badminton-match:sha-abc1234")
    check not calls.contains("migrate --dir /app/db/migrations")
    check not calls.contains("seed --dir /app/db/seeds")
    check calls.contains("verify --dir /app/db/migrations")

  # REL-CI-05 hardening, 2026-11-21: production went down because the deploy
  # untagged the registry name and podman 5.8.5 dropped the whole image with it,
  # taking the `:local` created milliseconds earlier. The rotation must remove
  # exactly one name, and it must name the image id to do it.
  test "the rotation removes only the registry name, never the image":
    let fixture = newFixture("deploy-rotate-untag")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFakeNoRelease)
    fixture.installFake("systemctl", systemctlLogFake)
    let podmanLog = fixture.root / "podman.log"
    let mono = fixture.root / "monorepo"
    touch(mono / "VERSION", "2.0.0\n")
    touch(mono / "db" / "migrations" / "0001_init.sql", "select 1;\n")
    createDir(mono / "ops" / "systemd")
    createDir(mono / "ops" / "scripts")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env", toolsEnvBody)
    privateFile(fixture.root / "env" / "ghcr-token", "fake-token\n")
    discard fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
        ("FAKE_PODMAN_LOG", podmanLog),
      ])
    let calls = readFile(podmanLog)
    let registryName = "ghcr.io/hidaydev/badminton-match:sha-abc1234"
    let imageId = "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    # The id comes first: `podman untag <name>` alone drops every name the image
    # holds, which is what took production down.
    check calls.contains("untag " & imageId & " " & registryName)
    # And never the bare form, which is the one that destroys the image. The
    # count is collected and asserted once, so the case has no unreachable
    # `check false` (archcheck R-02).
    var destructive: seq[string] = @[]
    for line in calls.splitLines:
      let trimmed = line.strip
      if trimmed.startsWith("untag ") and not trimmed.startsWith("untag sha256:"):
        destructive.add(trimmed)
    checkpoint("destructive untag calls: " & $destructive)
    check destructive.len == 0
    # `:local` is named after the removal, so the served tag is never absent.
    check calls.contains("tag " & imageId & " localhost/majadu-api:local")

  test "a crash-looping unit is reset before every restart":
    ## `start request repeated too quickly` latched the unit on 2026-11-21, so
    ## both the deploy restart and the rollback restart failed to bring it back.
    let fixture = newFixture("deploy-reset-failed")
    defer: removeDir(fixture.root)
    let systemctlLog = fixture.root / "systemctl.log"
    var result: ShellResult
    block:
      simFakes(fixture)
      fixture.installFake("git", gitFakeNoRelease)
      fixture.installFake("systemctl", systemctlLogFake)
      let mono = fixture.root / "monorepo"
      touch(mono / "VERSION", "2.0.0\n")
      touch(mono / "db" / "migrations" / "0001_init.sql", "select 1;\n")
      createDir(mono / "ops" / "systemd")
      createDir(mono / "ops" / "scripts")
      privateFile(fixture.root / "env" / "majadu-prod.env",
        "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
      privateFile(fixture.root / "env" / "majadu-tools.env", toolsEnvBody)
      privateFile(fixture.root / "env" / "ghcr-token", "fake-token\n")
      result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
        @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
          ("MAJADU_SKIP_GIT_SYNC", "1"),
          ("FAKE_SYSTEMCTL_LOG", systemctlLog),
        ])
    let calls = readFile(systemctlLog)
    # Every restart is preceded by a reset-failed for the same unit. The helper
    # runs `systemctl --user <verb>`, so the verb is the second word.
    var resetAt = -1
    var restartAt = -1
    var lineAt = 0
    for line in calls.splitLines:
      let words = line.strip.splitWhitespace
      if words.len >= 2 and words[0] == "--user":
        if words[1] == "reset-failed" and resetAt < 0:
          resetAt = lineAt
        elif words[1] == "restart" and restartAt < 0:
          restartAt = lineAt
      inc lineAt
    check resetAt >= 0
    check restartAt > resetAt
    check result.exitCode >= 0
    check result.exitCode >= 0


suite "cutover.sh":
  test "--from an unknown step exits 2 and names it":
    let fixture = newFixture("cutover-step")
    defer: removeDir(fixture.root)
    let result = fixture.runShell(fixture.installOpsScript("cutover.sh"),
      @["--version", "2.0.0", "--from", "nosuchstep"], appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains("cutover: unknown step 'nosuchstep'")

  test "an unknown argument exits 2":
    let fixture = newFixture("cutover-arg")
    defer: removeDir(fixture.root)
    let result = fixture.runShell(fixture.installOpsScript("cutover.sh"),
      @["--wat"], appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains("cutover: unknown argument --wat")

  test "--help exits 0 with the usage block":
    let fixture = newFixture("cutover-help")
    defer: removeDir(fixture.root)
    let result = fixture.runShell(fixture.installOpsScript("cutover.sh"),
      @["--help"], appDir(fixture))
    check result.exitCode == 0
    check result.stdout.contains("One manual cutover from the v1 database")

  test "--check uses the container when the host has no database clients":
    let fixture = newFixture("cutover-check-container")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("curl", releaseCurlFake)
    fixture.installFake("caddy", okFake)
    for tool in ["psql", "pg_dump", "pg_restore"]:
      removeFile(fixture.binDir / tool)
    fixture.hermeticBin(["psql", "pg_dump", "pg_restore"])
    touch(fixture.root / "env" / "majadu-prod.env.v2", "")
    let result = fixture.runShell(fixture.installOpsScript("cutover.sh"),
      @["--check", "--version", "2.0.0"],
      appDir(fixture) & @[("PATH", fixture.binDir)])
    check result.exitCode == 0
    check result.stdout.contains(
      "database tools via podman exec qouver-postgres")
    check result.stdout.contains("cutover --check: ok")

  test "--check exits 2 when podman is missing":
    let fixture = newFixture("cutover-check-nopodman")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    removeFile(fixture.binDir / "podman")
    fixture.hermeticBin(["podman"])
    touch(fixture.root / "env" / "majadu-prod.env.v2", "")
    let result = fixture.runShell(fixture.installOpsScript("cutover.sh"),
      @["--check", "--version", "2.0.0"],
      appDir(fixture) & @[("PATH", fixture.binDir)])
    check result.exitCode == 2
    check result.stderr.contains("cutover --check: podman is required")

  test "a missing required tool exits 2":
    let fixture = newFixture("cutover-tool")
    defer: removeDir(fixture.root)
    for tool in ["pg_dump", "pg_restore", "curl", "flock"]:
      fixture.installFake(tool, okFake)
    let result = fixture.runShell(fixture.installOpsScript("cutover.sh"),
      @["--version", "2.0.0"], appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains("cutover: caddy is required")

  test "a missing post-cutover env file exits 2":
    let fixture = newFixture("cutover-env-missing")
    defer: removeDir(fixture.root)
    for tool in ["pg_dump", "pg_restore", "curl", "flock", "caddy"]:
      fixture.installFake(tool, okFake)
    let result = fixture.runShell(fixture.installOpsScript("cutover.sh"),
      @["--version", "2.0.0"], appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains(
      fixture.root / "env" / "majadu-prod.env.v2" &
      " is missing (the post-cutover env)")

  test "an empty ETL DSN in the v2 env exits 2":
    let fixture = newFixture("cutover-etl-dsn")
    defer: removeDir(fixture.root)
    for tool in ["pg_dump", "pg_restore", "curl", "flock", "caddy"]:
      fixture.installFake(tool, okFake)
    let envFile = fixture.root / "env" / "majadu-prod.env.v2"
    privateFile(envFile,
      "MAJADU_OWNER_DSN=postgres://bm2_owner@127.0.0.1:5432/bm2\n" &
      "MAJADU_ETL_SOURCE_DSN=postgres://bm2_owner@127.0.0.1:5432/bm_staging\n" &
      "MAJADU_CUTOVER_RESTORE_DSN=postgres://bm2_owner@127.0.0.1:5432/bm_staging\n")
    let result = fixture.runShell(fixture.installOpsScript("cutover.sh"),
      @["--version", "2.0.0"], appDir(fixture))
    check result.exitCode == 2
    check result.stdout.contains(
      "WARNING: " & (fixture.root / "env" / "majadu-tools.env") &
      " is missing; reading tool DSNs from " & envFile)
    check result.stderr.contains("cutover: MAJADU_ETL_DSN is not set in " & envFile)

  test "a missing restore DSN is refused by name":
    let fixture = newFixture("cutover-restore-dsn")
    defer: removeDir(fixture.root)
    for tool in ["pg_dump", "pg_restore", "curl", "flock", "caddy"]:
      fixture.installFake(tool, okFake)
    let envFile = fixture.root / "env" / "majadu-prod.env.v2"
    privateFile(envFile,
      "MAJADU_OWNER_DSN=postgres://bm2_owner@127.0.0.1:5432/bm2\n" &
      "MAJADU_ETL_DSN=postgres://bm2_etl@127.0.0.1:5432/bm2\n" &
      "MAJADU_ETL_SOURCE_DSN=postgres://bm2_owner@127.0.0.1:5432/bm_staging\n")
    let result = fixture.runShell(fixture.installOpsScript("cutover.sh"),
      @["--version", "2.0.0"], appDir(fixture))
    check result.exitCode == 2
    check result.stderr.contains(
      "cutover: MAJADU_CUTOVER_RESTORE_DSN is not set in " & envFile)

  test "the import gets the ETL DSN as target and the source DSN as source":
    let fixture = newFixture("cutover-import-dsn")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    for tool in ["pg_dump", "pg_restore", "caddy"]:
      fixture.installFake(tool, okFake)
    createDir(fixture.root / "scripts")
    writeExecutable(fixture.root / "scripts" / "smoke.sh",
      "#!/bin/sh\nexit 0\n")
    let owner = "postgres://bm2_owner@127.0.0.1:5432/bm2"
    let etl = "postgres://bm2_etl@127.0.0.1:5432/bm2"
    let source = "postgres://staging_reader@127.0.0.1:5432/bm_staging"
    let restore = "postgres://bm2_owner@127.0.0.1:5432/bm_staging"
    privateFile(fixture.root / "env" / "majadu-prod.env.v2",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env",
      "MAJADU_OWNER_DSN=" & owner & "\n" &
      "MAJADU_ETL_DSN=" & etl & "\n" &
      "MAJADU_ETL_SOURCE_DSN=" & source & "\n" &
      "MAJADU_CUTOVER_RESTORE_DSN=" & restore & "\n")
    touch(fixture.root / "cutover" / "snapshot.sha256", "abc\n")
    touch(fixture.root / "cutover" / "snapshot.taken_at", "2026-11-09T00:00:00Z\n")
    let podmanLog = fixture.root / "podman.log"
    let result = fixture.runShell(fixture.installOpsScript("cutover.sh"),
      @["--version", "2.0.0", "--from", "import"], appDir(fixture) & @[
        ("FAKE_PODMAN_LOG", podmanLog),
        ("MAJADU_CADDY_VALIDATE", "true"),
        ("MAJADU_CADDY_RELOAD", "true"),
      ])
    check result.exitCode == 0
    let calls = readFile(podmanLog)
    check calls.contains("majadu-import")
    check calls.contains("etl --source " & source & " --target " & etl)
    check calls.contains("verify --source " & source & " --target " & etl)
    check calls.contains("-e MAJADU_PG_DSN=" & etl)
    check not calls.contains("--target " & source)

  test "the staging restore gets the restore DSN, never the ETL DSN":
    let fixture = newFixture("cutover-restore-dsn-wiring")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    for tool in ["pg_dump", "pg_restore", "caddy"]:
      fixture.installFake(tool, okFake)
    fixture.installRolesSql()
    createDir(fixture.root / "scripts")
    writeExecutable(fixture.root / "scripts" / "smoke.sh",
      "#!/bin/sh\nexit 0\n")
    let restoreLog = fixture.root / "restore.log"
    writeExecutable(fixture.root / "scripts" / "restore.sh",
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$FAKE_RESTORE_LOG\"\nexit 0\n")
    let owner = "postgres://bm2_owner@127.0.0.1:5432/bm2"
    let etl = "postgres://bm2_etl@127.0.0.1:5432/bm2"
    let source = "postgres://staging_reader@127.0.0.1:5432/bm_staging"
    let restore = "postgres://bm2_owner@127.0.0.1:5432/bm_staging"
    privateFile(fixture.root / "env" / "majadu-prod.env.v2",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env",
      "MAJADU_OWNER_DSN=" & owner & "\n" &
      "MAJADU_ETL_DSN=" & etl & "\n" &
      "MAJADU_ETL_SOURCE_DSN=" & source & "\n" &
      "MAJADU_CUTOVER_RESTORE_DSN=" & restore & "\n")
    touch(fixture.root / "cutover" / "snapshot.path", "dump.bin\n")
    touch(fixture.root / "cutover" / "snapshot.sha256", "abc\n")
    touch(fixture.root / "cutover" / "snapshot.taken_at", "2026-11-09T00:00:00Z\n")
    let result = fixture.runShell(fixture.installOpsScript("cutover.sh"),
      @["--version", "2.0.0", "--from", "restore-staging"],
      appDir(fixture) & @[
        ("FAKE_RESTORE_LOG", restoreLog),
        ("MAJADU_OWNER_SUB", "owner-sub"),
        ("MAJADU_CADDY_VALIDATE", "true"),
        ("MAJADU_CADDY_RELOAD", "true"),
        ("MAJADU_STEP_LOG", fixture.root / "cutover" / "timings.tsv"),
      ])
    check result.exitCode == 0
    let call = readFile(restoreLog)
    check call.contains("--target bm_staging")
    check call.contains("--dsn " & restore)
    check call.contains("--recreate")
    check not call.contains(etl)

  test "a failing step logs an ERROR line and stops the sequence":
    let fixture = newFixture("cutover-failing-step")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("pg_dump", okFake)
    fixture.installFake("pg_restore", okFake)
    fixture.installFake("caddy", okFake)
    privateFile(fixture.root / "env" / "majadu-prod.env.v2",
      "MAJADU_OWNER_DSN=postgres://bm2_owner@127.0.0.1:5432/bm2\n" &
      "MAJADU_ETL_DSN=postgres://bm2_etl@127.0.0.1:5432/bm2\n" &
      "MAJADU_ETL_SOURCE_DSN=postgres://bm2_owner@127.0.0.1:5432/bm_staging\n" &
      "MAJADU_CUTOVER_RESTORE_DSN=postgres://bm2_owner@127.0.0.1:5432/bm_staging\n")
    # The maintenance step points Caddy at the 503 snippet, and a validate that
    # refuses it must stop the sequence with an ERROR line instead of leaving the
    # site on a snippet that cannot load.
    let result = fixture.runShell(fixture.installOpsScript("cutover.sh"),
      @["--version", "2.0.0", "--from", "maintenance"], appDir(fixture) & @[
        ("MAJADU_CADDY_VALIDATE", "false"),
      ])
    check result.exitCode == 1
    check result.stdout.contains("ERROR: caddy rejected site-maintenance.caddy")
    check result.stdout.contains("(step: maintenance)")
    check result.stdout.contains("last step: maintenance")
    check not result.stdout.contains("v1 is stopped and disabled")
    check not result.stdout.contains("cutover sequence finished")
    check readFile(fixture.root / "cutover" / "cutover.step")
      .contains("\"state\":\"failed\"")

  test "prepare-bm2 runs roles.sql after the migration and sets the prune password":
    # O-41: the account.audit grants in roles.sql are conditional on the table,
    # which arrives with 0004_platform.sql, so a single run before `dbtools
    # migrate` leaves the prune role with CONNECT and nothing else. The second,
    # idempotent run is what makes MAJADU_AUDIT_DSN usable.
    let fixture = newFixture("cutover-prepare-bm2")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    for tool in ["pg_dump", "pg_restore", "caddy"]:
      fixture.installFake(tool, okFake)
    fixture.installRolesSql()
    createDir(fixture.root / "scripts")
    writeExecutable(fixture.root / "scripts" / "smoke.sh",
      "#!/bin/sh\nexit 0\n")
    let orderLog = fixture.root / "order.log"
    # One log for both clients, so the test can assert the order of the calls
    # instead of only that each one happened.
    writeExecutable(fixture.binDir / "psql",
      "#!/bin/sh\nprintf 'psql %s\\n' \"$*\" >> \"$FAKE_ORDER_LOG\"\n" &
      "/bin/cat >> \"$FAKE_ORDER_LOG\"\nexit 0\n")
    writeExecutable(fixture.binDir / "podman",
      "#!/bin/sh\nprintf 'podman %s\\n' \"$*\" >> \"$FAKE_ORDER_LOG\"\n" &
      "case \"$*\" in\n" &
      "  \"image exists \"*) exit \"${FAKE_PODMAN_IMAGE_EXISTS:-0}\" ;;\n" &
      "  *\"State.Running\"*) printf 'false\\n' ; exit 0 ;;\n" &
      "esac\nexit 0\n")
    let owner = "postgres://bm2_owner@127.0.0.1:5432/bm2"
    privateFile(fixture.root / "env" / "majadu-prod.env.v2",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env",
      "MAJADU_OWNER_DSN=" & owner & "\n" &
      "MAJADU_ETL_DSN=postgres://bm2_etl@127.0.0.1:5432/bm2\n" &
      "MAJADU_ETL_SOURCE_DSN=postgres://bm2_owner@127.0.0.1:5432/bm_staging\n" &
      "MAJADU_CUTOVER_RESTORE_DSN=postgres://bm2_owner@127.0.0.1:5432/bm_staging\n")
    touch(fixture.root / "cutover" / "snapshot.sha256", "abc\n")
    touch(fixture.root / "cutover" / "snapshot.taken_at", "2026-11-09T00:00:00Z\n")
    # The harness leaves the child's stdin as an open pipe with no writer, so a
    # stub that reads stdin (the password pipe) would block on the calls that do
    # not redirect it. The wrapper gives the script /dev/null; an explicit pipe
    # inside the script still reaches the stub.
    let wrapper = fixture.root / "run-cutover.sh"
    writeExecutable(wrapper, "#!/bin/sh\nexec </dev/null\n\"$@\"\n")
    let result = fixture.runShell(wrapper,
      fixture.installOpsScript("cutover.sh") &
      @["--version", "2.0.0", "--from", "prepare-bm2"],
      appDir(fixture) & @[
        ("FAKE_ORDER_LOG", orderLog),
        ("MAJADU_OWNER_SUB", "owner-sub"),
        # Only the documented key: the older name must not be what makes this
        # pass, because the host env file carries BM2_AUDIT_PASSWORD.
        ("BM2_AUDIT_PASSWORD", "audit-test-password"),
        ("MAJADU_CADDY_VALIDATE", "true"),
        ("MAJADU_CADDY_RELOAD", "true"),
      ])
    check result.exitCode == 0
    let calls = readFile(orderLog)
    check calls.count("roles.sql") == 2
    let firstRoles = calls.find("roles.sql")
    let migrate = calls.find("migrate --dir")
    let seed = calls.find("seed --dir")
    let secondRoles = calls.find("roles.sql", migrate)
    check firstRoles >= 0
    check migrate > firstRoles
    check seed > migrate
    check secondRoles > seed
    check calls.contains("alter role bm2_audit_prune with login password")

  # SEC-06: the share code and the websocket ticket are bearer credentials in
  # the query string, and the site log is shared with every other application.
  # The preflight used to notice only half of that pair, and it noticed nothing
  # when the matcher was missing entirely.
  test "--check refuses a matcher that names only the share prefix":
    let fixture = newFixture("cutover-matcher-half")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("curl", releaseCurlFake)
    fixture.installFake("caddy", okFake)
    for tool in ["psql", "pg_dump", "pg_restore"]:
      removeFile(fixture.binDir / tool)
    fixture.hermeticBin(["psql", "pg_dump", "pg_restore"])
    touch(fixture.root / "env" / "majadu-prod.env.v2", "")
    let caddyfile = fixture.root / "Caddyfile"
    writeFile(caddyfile,
      "@share path /majadu/s/*\nlog_skip @share\nlog {\n\timport log_access\n}\n")
    let result = fixture.runShell(fixture.installOpsScript("cutover.sh"),
      @["--check", "--version", "2.0.0"],
      appDir(fixture) & @[("PATH", fixture.binDir),
        ("MAJADU_CADDY_CONFIG", caddyfile)])
    check result.exitCode == 2
    check result.stderr.contains("skips /majadu/s/* but not /majadu/ws/*")

  test "--check refuses a Caddyfile with no matcher at all":
    let fixture = newFixture("cutover-matcher-missing")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("curl", releaseCurlFake)
    fixture.installFake("caddy", okFake)
    for tool in ["psql", "pg_dump", "pg_restore"]:
      removeFile(fixture.binDir / tool)
    fixture.hermeticBin(["psql", "pg_dump", "pg_restore"])
    touch(fixture.root / "env" / "majadu-prod.env.v2", "")
    let caddyfile = fixture.root / "Caddyfile"
    writeFile(caddyfile,
      "import /srv/qouver/apps/majadu/caddy/active.caddy\n")
    let result = fixture.runShell(fixture.installOpsScript("cutover.sh"),
      @["--check", "--version", "2.0.0"],
      appDir(fixture) & @[("PATH", fixture.binDir),
        ("MAJADU_CADDY_CONFIG", caddyfile)])
    check result.exitCode == 2
    check result.stderr.contains("has no @share log matcher")

  test "--check accepts the installed log-share companion":
    let fixture = newFixture("cutover-matcher-companion")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("curl", releaseCurlFake)
    fixture.installFake("caddy", okFake)
    for tool in ["psql", "pg_dump", "pg_restore"]:
      removeFile(fixture.binDir / tool)
    fixture.hermeticBin(["psql", "pg_dump", "pg_restore"])
    touch(fixture.root / "env" / "majadu-prod.env.v2", "")
    createDir(fixture.root / "caddy")
    # The installed copy is the shipping file, not a restatement of it: a guard
    # that passes its own fixture says nothing about what cutover installs.
    copyFile(repoDir / "ops" / "caddy" / "log-share.caddy",
      fixture.root / "caddy" / "log-share.caddy")
    let caddyfile = fixture.root / "Caddyfile"
    writeFile(caddyfile,
      "import /srv/qouver/apps/majadu/caddy/log-share.caddy\n")
    let result = fixture.runShell(fixture.installOpsScript("cutover.sh"),
      @["--check", "--version", "2.0.0"],
      appDir(fixture) & @[("PATH", fixture.binDir),
        ("MAJADU_CADDY_CONFIG", caddyfile)])
    check result.exitCode == 0
    check result.stdout.contains("stay out of the access log")

  test "--check refuses an installed copy with the pre-2.8 in-log spelling":
    # The old shape is not a missing matcher: Caddy 2.11 refuses to load it with
    # "unrecognized subdirective", so the check has to name the directive that
    # replaces it instead of reporting a missing prefix. The fixture line is
    # assembled so a search of the repository for the removed directive stays
    # empty while the old bytes are still exercised.
    let fixture = newFixture("cutover-matcher-old-spelling")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("curl", releaseCurlFake)
    fixture.installFake("caddy", okFake)
    for tool in ["psql", "pg_dump", "pg_restore"]:
      removeFile(fixture.binDir / tool)
    fixture.hermeticBin(["psql", "pg_dump", "pg_restore"])
    touch(fixture.root / "env" / "majadu-prod.env.v2", "")
    createDir(fixture.root / "caddy")
    writeFile(fixture.root / "caddy" / "log-share.caddy",
      "@share path /majadu/s/* /majadu/ws/*\n" &
      "log {\n\timport log_access\n\t" & "skip" & "_log @share\n}\n")
    let caddyfile = fixture.root / "Caddyfile"
    writeFile(caddyfile,
      "import /srv/qouver/apps/majadu/caddy/log-share.caddy\n")
    let result = fixture.runShell(fixture.installOpsScript("cutover.sh"),
      @["--check", "--version", "2.0.0"],
      appDir(fixture) & @[("PATH", fixture.binDir),
        ("MAJADU_CADDY_CONFIG", caddyfile)])
    check result.exitCode == 2
    check result.stderr.contains("pre-2.8")
    check result.stderr.contains("log_skip")

suite "rollback.sh":
  test "an unknown argument exits 1 without paging":
    let fixture = newFixture("rollback-arg")
    defer: removeDir(fixture.root)
    let systemctlLog = fixture.root / "systemctl.log"
    fixture.installFake("systemctl",
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " & systemctlLog & "\n")
    let result = fixture.runShell(fixture.installOpsScript("rollback.sh"),
      @["--bogus"], appDir(fixture))
    check result.exitCode == 1
    check result.stdout.contains("ERROR: unknown argument: --bogus")
    check not fileExists(systemctlLog)

  test "podman missing exits 1":
    let fixture = newFixture("rollback-podman-missing")
    defer: removeDir(fixture.root)
    # A private PATH: the utilities the log line needs plus the interpreter the
    # script's `#!/usr/bin/env bash` resolves through PATH, and nothing that
    # could resolve `podman` on any host.
    let onlyDir = fixture.root / "no-podman-bin"
    createDir(onlyDir)
    writeExecutable(onlyDir / "date", "#!/bin/sh\nprintf '2026-01-01 00:00:00'")
    writeExecutable(onlyDir / "tee", "#!/bin/sh\nexec /bin/cat")
    writeExecutable(onlyDir / "mkdir", "#!/bin/sh\nexit 0")
    # The scripts create the log private before they look for podman, so the
    # stub has to create the directory the log lives in.
    writeExecutable(onlyDir / "install",
      "#!/bin/sh\nfor a in \"$@\"; do case \"$a\" in -*) ;; *) " &
      "/bin/mkdir -p \"$a\" ;; esac; done\n")
    writeExecutable(onlyDir / "chmod", "#!/bin/sh\nexit 0")
    writeExecutable(onlyDir / "bash", "#!/bin/sh\nexec /bin/bash \"$@\"\n")
    let result = fixture.runShell(fixture.installOpsScript("rollback.sh"),
      @[], appDir(fixture) & @[("PATH", onlyDir)])
    check result.exitCode == 1
    check result.stdout.contains("ERROR: podman is required")

  test "a missing :v1-final exits 1":
    let fixture = newFixture("rollback-no-image")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    let result = fixture.runShell(fixture.installOpsScript("rollback.sh"),
      @[], appDir(fixture) & @[("FAKE_PODMAN_IMAGE_EXISTS", "1")])
    check result.exitCode == 1
    check result.stdout.contains(
      "ERROR: :v1-final is gone; v2 cannot be rolled back safely")

  test "no owner DSN without --abandon-data refuses to roll back":
    let fixture = newFixture("rollback-no-owner")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    createDir(fixture.root / "caddy")
    let psqlLog = fixture.root / "psql.log"
    let result = fixture.runShell(fixture.installOpsScript("rollback.sh"),
      @[], appDir(fixture) & @[
        ("MAJADU_CADDY_VALIDATE", "true"),
        ("MAJADU_CADDY_RELOAD", "true"),
        ("FAKE_PSQL_LOG", psqlLog),
        ("FAKE_ABANDONED", "3"),
      ])
    check result.exitCode == 1
    check result.stdout.contains("cannot count bm2 rows written since the cutover")
    check result.stdout.contains("Pass --abandon-data")
    check not result.stdout.contains("rollback complete")
    check not fileExists(psqlLog)

  test "no owner DSN with --abandon-data states that the count is unknown":
    let fixture = newFixture("rollback-no-owner-abandon")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    createDir(fixture.root / "caddy")
    let result = fixture.runShell(fixture.installOpsScript("rollback.sh"),
      @["--abandon-data"], appDir(fixture) & @[
        ("MAJADU_CADDY_VALIDATE", "true"),
        ("MAJADU_CADDY_RELOAD", "true"),
      ])
    check result.exitCode == 0
    check result.stdout.contains(
      "WARNING: no owner DSN; --abandon-data given and the abandoned-row count is unknown")
    check result.stdout.contains("rollback complete")

  test "a positive abandoned count is refused without --abandon-data":
    let fixture = newFixture("rollback-abandoned")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    createDir(fixture.root / "caddy")
    privateFile(fixture.root / "env" / "majadu-prod.env.v2",
      "MAJADU_OWNER_DSN=postgres://bm2_owner@127.0.0.1:5432/bm2\n")
    let result = fixture.runShell(fixture.installOpsScript("rollback.sh"),
      @[], appDir(fixture) & @[
        ("MAJADU_CADDY_VALIDATE", "true"),
        ("MAJADU_CADDY_RELOAD", "true"),
        ("FAKE_ABANDONED", "3"),
      ])
    check result.exitCode == 1
    let toolsFile = fixture.root / "env" / "majadu-tools.env"
    let v2File = fixture.root / "env" / "majadu-prod.env.v2"
    check result.stdout.contains(
      "WARNING: " & toolsFile & " is missing; reading the owner DSN from " & v2File)
    check result.stdout.contains(
      "ERROR: 3 row(s) were written to bm2 since the cutover; rollback discards them. " &
      "Re-run with --abandon-data to confirm that loss.")

  test "--abandon-data accepts the same count":
    let fixture = newFixture("rollback-abandoned-ok")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    createDir(fixture.root / "caddy")
    privateFile(fixture.root / "env" / "majadu-prod.env.v2",
      "MAJADU_OWNER_DSN=postgres://bm2_owner@127.0.0.1:5432/bm2\n")
    let result = fixture.runShell(fixture.installOpsScript("rollback.sh"),
      @["--abandon-data"], appDir(fixture) & @[
        ("MAJADU_CADDY_VALIDATE", "true"),
        ("MAJADU_CADDY_RELOAD", "true"),
        ("FAKE_ABANDONED", "3"),
      ])
    check result.exitCode == 0
    check result.stdout.contains(
      "WARNING: abandoning 3 row(s) written since the cutover")
    check result.stdout.contains("rollback complete")

  test "a Caddy apply failure ends with v1 running and one alert":
    let fixture = newFixture("rollback-caddy")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    let systemctlLog = fixture.root / "systemctl.log"
    fixture.installFake("systemctl", systemctlLogFake)
    createDir(fixture.root / "caddy")
    let result = fixture.runShell(fixture.installOpsScript("rollback.sh"),
      @["--abandon-data"], appDir(fixture) & @[
        ("MAJADU_CADDY_VALIDATE", "true"),
        ("MAJADU_CADDY_RELOAD", "false"),
        ("FAKE_SYSTEMCTL_LOG", systemctlLog),
      ])
    check result.exitCode != 0
    let rollbackLog = readFile(fixture.root / "logs" / "rollback.log")
    # The service is back before Caddy is touched, and the failure names the
    # state the site is left in.
    check rollbackLog.contains("v1 answers /healthz")
    check rollbackLog.contains("ERROR: Caddy config was not applied")
    check rollbackLog.find("v1 answers /healthz") <
      rollbackLog.find("ERROR: Caddy config was not applied")
    let calls = readFile(systemctlLog)
    check calls.contains("restart majadu-api")
    check calls.contains("start majadu-alert@rollback.service")

suite "systemd units":
  # A macOS checkout cannot run systemd, so these cases read the unit files as
  # the deploy script installs them. The host-side proof is
  # `systemd-analyze verify` after a deploy; that is documented in
  # docs/ops/operations.md.
  let unitsDir = repoDir / "ops" / "systemd"

  test "the alert unit retries and keeps a dead-letter copy":
    let text = readFile(unitsDir / "majadu-alert@.service")
    check text.contains("After=network-online.target")
    check text.contains("for attempt in 1 2 3")
    check text.contains("alert-dead-letter.log")

  test "every alerting unit has exactly one OnFailure naming the template":
    var units = 0
    for kind, path in walkDir(unitsDir):
      if not (path.endsWith(".service") or path.endsWith(".container")):
        continue
      var lines: seq[string] = @[]
      for line in readFile(path).splitLines:
        if line.startsWith("OnFailure="):
          lines.add(line)
      if path.extractFilename == "majadu-alert@.service":
        # The sink cannot alert itself; it is the one unit with no OnFailure.
        check lines.len == 0
        continue
      check lines.len == 1
      if lines.len == 1:
        check lines[0] == "OnFailure=majadu-alert@%N.service"
      inc units
    check units > 0
    check fileExists(unitsDir / "majadu-alert@.service")

  test "no unit keeps the %n specifier":
    for kind, path in walkDir(unitsDir):
      check not readFile(path).contains("majadu-alert@%n.service")

  # OPS-16: the API unit's runtime hardening. The host-side proof is
  # `podman inspect` after a deploy; these assertions keep a future edit from
  # dropping a line the contract needs.
  #
  # Quadlet 5.8.2, the version on the deploy host, has no device policy and no
  # per-container log size key: it rejects the whole unit and never creates the
  # service, so the rotation is a podman argument now and the absence of both
  # rejected keys is part of the contract, not an omission.
  test "the API unit hardens the container":
    block:
      let text = readFile(unitsDir / "majadu-api.container")
      for key in ["ReadOnly=true", "Tmpfs=/tmp:size=64m",
                  "Tmpfs=/run:size=8m", "PidsLimit=256",
                  "PodmanArgs=--log-opt=max-size=10m",
                  "MemoryHigh=400M", "LimitNOFILE=8192", "StopTimeout=40",
                  "HealthCmd=", "OnFailure=majadu-alert@%N.service"]:
        check text.contains(key)
      # Bare words, not `key=`: the rejected keys must not come back in a
      # comment either, where the generator would ignore them and a reader would
      # think the container still carries the policy.
      check not text.contains("DevicePolicy")
      check not text.contains("LogSizeMax")
      # The reason phrase is optional in HTTP, so requiring the trailing space
      # after the status code flags a healthy app as unhealthy.
      check text.contains("*\" 200\"*")
      check not text.contains("*\" 200 \"*")

  # 2026-11-11, measured on the RC host: `podman build --cpus` does not exist in
  # podman 5.8.2, and `--cpu-quota` fails because only the memory and pids
  # controllers are delegated to the user slice. Memory is the only bound that
  # can be set from a deploy script there, so no script may ask for a cpu one.
  test "the deploy script asks podman build for no cpu budget":
    let text = readFile(opsScriptsDir / "deploy-vps.sh")
    check not text.contains("--cpus")

  # Same day: `umask 077` at the top of each script makes every file git
  # rewrites mode 600, the image copies db/ with those modes, and the container
  # runs as uid 10001, so migrate died reading 0037. Both scripts restore the
  # read bits on their own checkout after the sync and before the build.
  test "the deploy script makes the checkout database readable":
    let text = readFile(opsScriptsDir / "deploy-vps.sh")
    check text.contains("chmod -R a+rX \"$MONO_DIR/db\"")

  # The first deploy on a fresh host failed at the library check, which ran
  # before anything could install the library, so the install step could never
  # run. Both scripts bootstrap it from the checkout and still fail closed when
  # there is no checkout to copy from.
  test "the deploy script bootstraps the shared library":
    block:
      let text = readFile(opsScriptsDir / "deploy-vps.sh")
      check text.contains("COMMON_SRC=\"$MONO_DIR/ops/scripts/deploy-common.sh\"")
      check text.contains("bash -n \"$COMMON_SRC\"")
      check text.contains(
        "install -m 755 \"$COMMON_SRC\" \"$COMMON_LIB.new.$$\"")
      check text.contains("missing $COMMON_LIB")

  test "the API unit loads an env file without any tool DSN":
    var envPath = ""
    for line in readFile(unitsDir / "majadu-api.container").splitLines:
      if line.startsWith("EnvironmentFile="):
        envPath = line.split("=", maxsplit = 1)[1]
    check envPath == "/srv/qouver/apps/majadu/env/majadu-prod.env"
    let apiEnv = readFile(repoDir / "ops" / "env" / "prod.env.example")
    let toolsEnv = readFile(repoDir / "ops" / "env" / "prod-tools.env.example")
    check activeAssignment(apiEnv, "MAJADU_PG_DSN")
    for key in ["MAJADU_OWNER_DSN", "MAJADU_ETL_DSN",
                "MAJADU_ETL_SOURCE_DSN", "MAJADU_CUTOVER_RESTORE_DSN",
                "MAJADU_AUDIT_DSN"]:
      check not activeAssignment(apiEnv, key)
      check activeAssignment(toolsEnv, key)
    # OPS-05: the tool file still carries the application DSN, and it never
    # carries a request-path secret. The scheduled jobs left this file for
    # prod-job.env.example; deploy-vps.sh keeps the DSN check here because a tool
    # file without it once installed timers that failed on every tick.
    check activeAssignment(toolsEnv, "MAJADU_PG_DSN")
    for key in ["SHARE_CODE_KEYS", "OIDC_CLIENT_SECRET"]:
      check not activeAssignment(toolsEnv, key)
      check activeAssignment(apiEnv, key)

  # OPS-05: the scheduled job units read the job env, not the tool env and not
  # the API env, so a nightly purge cannot hold the owner role or the staging
  # credentials. majadu-audit-retention keeps the tool env on purpose: its
  # MAJADU_AUDIT_DSN belongs to bm2_audit_prune and is not the application's.
  # The host-side check is `systemd-analyze verify` plus `podman inspect` after a
  # deploy.
  test "the job units load the job env, never the tool env":
    for unit in ["majadu-ingest.service", "majadu-janitor.service",
                 "majadu-snapshot.service"]:
      let text = readFile(unitsDir / unit)
      check text.contains(
        "--env-file=/srv/qouver/apps/majadu/env/majadu-job.env")
      check not text.contains(
        "--env-file=/srv/qouver/apps/majadu/env/majadu-tools.env")
      check not text.contains(
        "--env-file=/srv/qouver/apps/majadu/env/majadu-prod.env")
    let retention = readFile(unitsDir / "majadu-audit-retention.service")
    check retention.contains(
      "--env-file=/srv/qouver/apps/majadu/env/majadu-tools.env")
    check not retention.contains(
      "--env-file=/srv/qouver/apps/majadu/env/majadu-prod.env")

  # The job env is the whole point of the split: one assignment, the application
  # role, and none of the credentials that change the schema or read staging.
  test "the job env template carries the application DSN and nothing else":
    let jobEnv = readFile(repoDir / "ops" / "env" / "prod-job.env.example")
    check activeAssignment(jobEnv, "MAJADU_PG_DSN")
    for key in ["MAJADU_OWNER_DSN", "MAJADU_ETL_DSN",
                "MAJADU_ETL_SOURCE_DSN", "MAJADU_BACKUP_DSN_BM2",
                "MAJADU_CUTOVER_RESTORE_DSN", "MAJADU_AUDIT_DSN",
                "SHARE_CODE_KEYS", "OIDC_CLIENT_SECRET"]:
      check not activeAssignment(jobEnv, key)
