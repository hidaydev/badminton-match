# TL-20: the deploy and rollback guards (`deploy-vps.sh`, `deploy-vps-rc.sh`,
# `cutover.sh`, `rollback.sh`, `bootstrap-rc.sh`).
#
# Every case points `MAJADU_APP_DIR`/`MAJADU_RC_APP_DIR` at a temp directory and
# answers the process edges with fakes on the fixture PATH (`podman`, `psql`,
# `curl`, `flock`, `git`). No case reaches `/srv`, a database or a host.
#
# The guards are all reached before the first real side effect, so each case
# stops inside the guard it names instead of deploys.

import std/[os, strutils, unittest]
import ../harness

const okFake = """#!/bin/sh
exit 0
"""

const podmanFake = """#!/bin/sh
if [ -n "${FAKE_PODMAN_LOG:-}" ]; then
  printf '%s\n' "$*" >>"$FAKE_PODMAN_LOG"
fi
case "$*" in
  "image exists "*) exit "${FAKE_PODMAN_IMAGE_EXISTS:-0}" ;;
  *"datname = 'bm2'"*) printf '%s\n' "${FAKE_BM2_EXISTS:-}" ; exit 0 ;;
  *"datname = 'bm2_rc'"*) printf '1\n' ; exit 0 ;;
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
esac
exit 0
"""

# The release API plus the health probes: deploy-vps.sh reads the digest from
# the release body and treats any curl exit 0 as a ready endpoint.
const releaseCurlFake = """#!/bin/sh
case "$*" in
  *api.github.com*) printf '%s' '{"body":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}' ;;
esac
exit 0
"""

const systemctlLogFake = """#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"
exit 0
"""

# GitHub answers the CI gate from FAKE_CI_BODY for the pinned ci.yml endpoint
# and FAKE_OTHER_RUNS for any other endpoint; FAKE_CI_EXIT stands in for a
# network or HTTP failure. FAKE_CI_BODY_AFTER, with FAKE_CI_COUNTER, serves a
# different body from the second call so a wait can be exercised. Every other
# URL is a health probe: exit 0 is enough.
const ciCurlFake = """#!/bin/sh
if [ -n "${FAKE_CURL_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$FAKE_CURL_LOG"
fi
call=1
if [ -n "${FAKE_CI_COUNTER:-}" ]; then
  call=$(cat "$FAKE_CI_COUNTER" 2>/dev/null || echo 0)
  call=$((call + 1))
  printf '%s' "$call" >"$FAKE_CI_COUNTER"
fi
case "$*" in
  *"/actions/workflows/ci.yml/runs"*)
    [ "${FAKE_CI_EXIT:-0}" = "0" ] || exit "$FAKE_CI_EXIT"
    if [ "$call" -ge 2 ] && [ -n "${FAKE_CI_BODY_AFTER-}" ]; then
      printf '%s' "$FAKE_CI_BODY_AFTER"
    else
      printf '%s' "${FAKE_CI_BODY-}"
    fi
    ;;
  *api.github.com*)
    [ "${FAKE_CI_EXIT:-0}" = "0" ] || exit "$FAKE_CI_EXIT"
    printf '%s' "${FAKE_OTHER_RUNS-}"
    ;;
esac
exit 0
"""

const ciSuccessBody = """{"total_count":1,"workflow_runs":[{"id":101,"name":"CI","run_number":7,"status":"completed","conclusion":"success","repository":{"id":555}}]}"""
const ciFailureBody = """{"total_count":1,"workflow_runs":[{"id":102,"name":"CI","run_number":8,"status":"completed","conclusion":"failure"}]}"""
const ciCancelledBody = """{"total_count":1,"workflow_runs":[{"id":103,"name":"CI","run_number":9,"status":"completed","conclusion":"cancelled"}]}"""
const ciNullConclusionBody = """{"total_count":1,"workflow_runs":[{"id":104,"name":"CI","run_number":10,"status":"completed","conclusion":null}]}"""
const ciPendingBody = """{"total_count":1,"workflow_runs":[{"id":105,"name":"CI","run_number":11,"status":"in_progress","conclusion":null}]}"""
const ciMissingBody = """{"total_count":0,"workflow_runs":[]}"""
const ciOrderedBody = """{"total_count":2,"workflow_runs":[{"id":100,"name":"CI","run_number":5,"status":"completed","conclusion":"success"},{"id":200,"name":"CI","run_number":6,"status":"completed","conclusion":"failure"}]}"""
const ciTooManyBody = """{"total_count":101,"workflow_runs":[]}"""
const ciMissingRunNumberBody = """{"total_count":2,"workflow_runs":[{"id":300,"name":"CI","status":"completed","conclusion":"failure"},{"id":200,"name":"CI","run_number":6,"status":"completed","conclusion":"success"}]}"""

proc touch(path: string, body = "") =
  createDir(path.parentDir)
  writeFile(path, body)

proc appDir(fixture: Fixture, dir: string = ""): seq[(string, string)] =
  @[("MAJADU_APP_DIR", if dir.len > 0: dir else: fixture.root)]

proc privateFile(path, body: string) =
  touch(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite})

proc simFakes(fixture: Fixture) =
  ## The process edges a simulated deploy needs: no lock contention, a green
  ## health endpoint, a podman that answers `image exists` and a psql that logs.
  fixture.installFake("flock", okFake)
  fixture.installFake("curl", okFake)
  fixture.installFake("podman", podmanFake)
  fixture.installFake("psql", psqlFake)

proc rcGateFixture(fixture: Fixture, token = true): string =
  ## Builds the RC tree up to the CI gate: a checkout with VERSION and the
  ## script, an installed copy, and a private env file that points at bm2_rc.
  simFakes(fixture)
  fixture.installFake("git", gitFake)
  fixture.installFake("curl", ciCurlFake)
  let rcDir = fixture.root / "rc"
  let mono = rcDir / "repo"
  touch(mono / "VERSION", "2.0.0\n")
  let source = mono / "ops" / "scripts" / "deploy-vps-rc.sh"
  createDir(source.parentDir)
  copyFile(opsScriptsDir / "deploy-vps-rc.sh", source)
  touch(rcDir / "scripts" / "deploy-vps-rc.sh", "old copy\n")
  privateFile(rcDir / "env" / "majadu-rc.env",
    "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2_rc\n")
  privateFile(rcDir / "env" / "majadu-rc-tools.env",
    "MAJADU_OWNER_DSN=postgres://bm2_owner@127.0.0.1:5432/bm2_rc\n")
  if token:
    privateFile(rcDir / "env" / "github-token", "secret-token\n")
  rcDir

proc runRcGate(fixture: Fixture, rcDir: string,
    extra: seq[(string, string)] = @[]): ShellResult =
  fixture.runShell(fixture.installOpsScript("deploy-vps-rc.sh"),
    @["badminton-match", "refs/heads/release/2.0.0-rc.1"],
    @[("MAJADU_RC_APP_DIR", rcDir), ("MAJADU_RC_SKIP_GIT_SYNC", "1"),
      ("MAJADU_RC_CI_WAIT_ATTEMPTS", "1")] & extra)

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

  test "a failure inside the restart step logs, records and alerts":
    let fixture = newFixture("deploy-restart-trap")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    fixture.installFake("curl", releaseCurlFake)
    let systemctlLog = fixture.root / "systemctl.log"
    fixture.installFake("systemctl", systemctlLogFake)
    let mono = fixture.root / "monorepo"
    touch(mono / "VERSION", "2.0.0\n")
    touch(mono / "db" / "migrations" / "0001_init.sql", "select 1;\n")
    createDir(mono / "ops" / "systemd")
    createDir(mono / "ops" / "scripts")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env",
      "MAJADU_OWNER_DSN=postgres://bm2_owner@127.0.0.1:5432/bm2\n")
    # A token file keeps AUTH non-empty (bash 3.2 treats "${AUTH[@]}" on an
    # empty array as unbound under set -u) and the podman fake answers login.
    privateFile(fixture.root / "env" / "ghcr-token", "fake-token\n")
    # Everything before the restart succeeds; `false` stands in for a systemctl
    # that refuses the restart, which used to exit through set -e without a log
    # line, an alert or a state record.
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
        ("MAJADU_SERVICE_CMD", "false"),
        ("FAKE_SYSTEMCTL_LOG", systemctlLog),
      ])
    check result.exitCode != 0
    let deployLog = readFile(fixture.root / "logs" / "deploy.log")
    check deployLog.contains("ERROR: command failed at line")
    check deployLog.contains("(step: restart)")
    check readFile(fixture.root / "deploy" / "last-release.json")
      .contains("\"step\":\"restart\"")
    check readFile(systemctlLog).contains("start majadu-alert@deploy.service")

  test "an owner DSN left in the API env stops the deploy":
    let fixture = newFixture("deploy-api-env-owner")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    createDir(fixture.root / "monorepo")
    privateFile(fixture.root / "env" / "majadu-prod.env",
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2\n" &
      "MAJADU_OWNER_DSN=postgres://bm2_owner@127.0.0.1:5432/bm2\n")
    privateFile(fixture.root / "env" / "majadu-tools.env",
      "MAJADU_OWNER_DSN=postgres://bm2_owner@127.0.0.1:5432/bm2\n")
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps.sh"),
      @["badminton-match", "refs/heads/main"], appDir(fixture) & @[
        ("MAJADU_SKIP_GIT_SYNC", "1"),
      ])
    check result.exitCode == 1
    let envFile = fixture.root / "env" / "majadu-prod.env"
    let toolsFile = fixture.root / "env" / "majadu-tools.env"
    check result.stdout.contains(
      envFile & " must not contain MAJADU_OWNER_DSN; move it to " & toolsFile)
    check readFile(fixture.root / "deploy" / "last-release.json")
      .contains("\"step\":\"env-split\"")

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
    check not result.stdout.contains("release v")

suite "deploy-vps-rc.sh":
  test "a ref other than the RC branch is ignored":
    let fixture = newFixture("rc-other-ref")
    defer: removeDir(fixture.root)
    let rcDir = fixture.root / "rc"
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps-rc.sh"),
      @["badminton-match", "refs/heads/main"],
      appDir(fixture, rcDir) & @[("MAJADU_RC_APP_DIR", rcDir)])
    check result.exitCode == 0
    check result.stdout.contains(
      "deploy ignored: ref 'refs/heads/main' is not refs/heads/release/2.0.0-rc.1")
    check not result.stdout.contains("deploy trigger")

  test "the RC ref reaches the deploy trigger":
    let fixture = newFixture("rc-accepted-ref")
    defer: removeDir(fixture.root)
    let rcDir = fixture.root / "rc"
    createDir(rcDir / "repo")
    simFakes(fixture)
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps-rc.sh"),
      @["badminton-match", "refs/heads/release/2.0.0-rc.1"],
      @[("MAJADU_RC_APP_DIR", rcDir), ("MAJADU_APP_DIR", rcDir),
        ("MAJADU_RC_SKIP_GIT_SYNC", "1")])
    check result.stdout.contains(
      "deploy trigger for badminton-match refs/heads/release/2.0.0-rc.1")
    check not result.stdout.contains("deploy ignored")
    # Past the guard, the checkout has no git metadata and the trap stops the
    # run: the guard is what the case is about, not the deploy that follows.
    check result.exitCode != 0

  test "MAJADU_RC_BRANCH moves the accepted ref":
    let fixture = newFixture("rc-branch-override")
    defer: removeDir(fixture.root)
    let rcDir = fixture.root / "rc"
    createDir(rcDir / "repo")
    simFakes(fixture)
    let script = fixture.installOpsScript("deploy-vps-rc.sh")
    let env = @[("MAJADU_RC_APP_DIR", rcDir), ("MAJADU_APP_DIR", rcDir),
      ("MAJADU_RC_SKIP_GIT_SYNC", "1"), ("MAJADU_RC_BRANCH", "release/3.0.0")]
    let accepted = fixture.runShell(script,
      @["badminton-match", "refs/heads/release/3.0.0"], env)
    check accepted.stdout.contains(
      "deploy trigger for badminton-match refs/heads/release/3.0.0")
    check not accepted.stdout.contains("deploy ignored")
    let oldRef = fixture.runShell(script,
      @["badminton-match", "refs/heads/release/2.0.0-rc.1"], env)
    check oldRef.exitCode == 0
    check oldRef.stdout.contains(
      "deploy ignored: ref 'refs/heads/release/2.0.0-rc.1' is not refs/heads/release/3.0.0")

  test "an incoming script that fails bash -n is not installed":
    let fixture = newFixture("rc-install-syntax")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    let rcDir = fixture.root / "rc"
    let mono = rcDir / "repo"
    touch(mono / "VERSION", "2.0.0\n")
    touch(mono / "ops" / "scripts" / "deploy-vps-rc.sh", "if true; then\n")
    let installed = rcDir / "scripts" / "deploy-vps-rc.sh"
    touch(installed, "old copy\n")
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps-rc.sh"),
      @["badminton-match", "refs/heads/release/2.0.0-rc.1"],
      @[("MAJADU_RC_APP_DIR", rcDir), ("MAJADU_RC_SKIP_GIT_SYNC", "1")])
    check result.exitCode != 0
    check result.stdout.contains("does not pass bash -n")
    check readFile(installed) == "old copy\n"

  test "a valid incoming script replaces the installed copy":
    let fixture = newFixture("rc-install-valid")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    fixture.installFake("git", gitFake)
    let rcDir = fixture.root / "rc"
    let mono = rcDir / "repo"
    touch(mono / "VERSION", "2.0.0\n")
    let source = mono / "ops" / "scripts" / "deploy-vps-rc.sh"
    createDir(source.parentDir)
    copyFile(opsScriptsDir / "deploy-vps-rc.sh", source)
    let installed = rcDir / "scripts" / "deploy-vps-rc.sh"
    touch(installed, "old copy\n")
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps-rc.sh"),
      @["badminton-match", "refs/heads/release/2.0.0-rc.1"],
      @[("MAJADU_RC_APP_DIR", rcDir), ("MAJADU_RC_SKIP_GIT_SYNC", "1")])
    # The refresh happens before the env guard, which stops the run; the case is
    # about the install, not the deploy that follows.
    check result.exitCode != 0
    check readFile(installed) == readFile(source)
    check readFile(rcDir / "deploy" / "last-release.json")
      .contains("\"step\":\"env-check\"")

  test "the CI gate allows a commit whose ci.yml run succeeded":
    let fixture = newFixture("rc-ci-success")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture)
    let curlLog = fixture.root / "curl.log"
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps-rc.sh"),
      @["badminton-match", "refs/heads/release/2.0.0-rc.1"],
      @[("MAJADU_RC_APP_DIR", rcDir), ("MAJADU_RC_SKIP_GIT_SYNC", "1"),
        ("MAJADU_RC_CI_WAIT_ATTEMPTS", "1"),
        ("FAKE_CI_BODY", ciSuccessBody), ("FAKE_CURL_LOG", curlLog)])
    check result.stdout.contains("ci gate: abc1234 passed ci.yml")
    check result.stdout.contains(
      "built localhost/majadu-rc-api:local at abc1234")
    # The query is pinned to the CI workflow, and the token never reaches argv.
    check readFile(curlLog).contains("/actions/workflows/ci.yml/runs")
    check not readFile(curlLog).contains("secret-token")
    for kind, path in walkDir(rcDir / "deploy"):
      check not path.extractFilename.startsWith("ci-auth")

  test "a successful Coverage run for the SHA does not satisfy the gate":
    let fixture = newFixture("rc-ci-scope")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture)
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps-rc.sh"),
      @["badminton-match", "refs/heads/release/2.0.0-rc.1"],
      @[("MAJADU_RC_APP_DIR", rcDir), ("MAJADU_RC_SKIP_GIT_SYNC", "1"),
        ("MAJADU_RC_CI_WAIT_ATTEMPTS", "1"),
        ("FAKE_CI_BODY", ciMissingBody), ("FAKE_OTHER_RUNS", ciSuccessBody)])
    check result.exitCode == 1
    check result.stdout.contains("no ci.yml run yet for abc1234")
    check not result.stdout.contains(
      "built localhost/majadu-rc-api:local")

  test "an unrelated cancelled run does not block a successful ci.yml":
    let fixture = newFixture("rc-ci-unrelated")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture)
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps-rc.sh"),
      @["badminton-match", "refs/heads/release/2.0.0-rc.1"],
      @[("MAJADU_RC_APP_DIR", rcDir), ("MAJADU_RC_SKIP_GIT_SYNC", "1"),
        ("MAJADU_RC_CI_WAIT_ATTEMPTS", "1"),
        ("FAKE_CI_BODY", ciSuccessBody), ("FAKE_OTHER_RUNS", ciCancelledBody)])
    check result.stdout.contains("ci gate: abc1234 passed ci.yml")
    check result.stdout.contains(
      "built localhost/majadu-rc-api:local at abc1234")

  test "the CI gate refuses a failed ci.yml run":
    let fixture = newFixture("rc-ci-failed")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture)
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps-rc.sh"),
      @["badminton-match", "refs/heads/release/2.0.0-rc.1"],
      @[("MAJADU_RC_APP_DIR", rcDir), ("MAJADU_RC_SKIP_GIT_SYNC", "1"),
        ("MAJADU_RC_CI_WAIT_ATTEMPTS", "1"),
        ("FAKE_CI_BODY", ciFailureBody)])
    check result.exitCode == 1
    check result.stdout.contains(
      "newest ci.yml run for abc1234 ended as failure")
    check not result.stdout.contains(
      "built localhost/majadu-rc-api:local")
    check readFile(rcDir / "deploy" / "last-release.json")
      .contains("\"step\":\"ci-gate\"")

  test "the CI gate refuses a completed run with a null conclusion":
    let fixture = newFixture("rc-ci-null")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture)
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps-rc.sh"),
      @["badminton-match", "refs/heads/release/2.0.0-rc.1"],
      @[("MAJADU_RC_APP_DIR", rcDir), ("MAJADU_RC_SKIP_GIT_SYNC", "1"),
        ("MAJADU_RC_CI_WAIT_ATTEMPTS", "1"),
        ("FAKE_CI_BODY", ciNullConclusionBody)])
    check result.exitCode == 1
    check result.stdout.contains(
      "newest ci.yml run for abc1234 completed without a conclusion")
    check not result.stdout.contains(
      "built localhost/majadu-rc-api:local")

  test "the CI gate refuses an empty response":
    let fixture = newFixture("rc-ci-empty")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture)
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps-rc.sh"),
      @["badminton-match", "refs/heads/release/2.0.0-rc.1"],
      @[("MAJADU_RC_APP_DIR", rcDir), ("MAJADU_RC_SKIP_GIT_SYNC", "1"),
        ("MAJADU_RC_CI_WAIT_ATTEMPTS", "1"), ("FAKE_CI_BODY", "")])
    check result.exitCode == 1
    check result.stdout.contains("empty or malformed response for abc1234")
    check not result.stdout.contains(
      "built localhost/majadu-rc-api:local")

  test "the CI gate refuses a malformed response":
    let fixture = newFixture("rc-ci-malformed")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture)
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps-rc.sh"),
      @["badminton-match", "refs/heads/release/2.0.0-rc.1"],
      @[("MAJADU_RC_APP_DIR", rcDir), ("MAJADU_RC_SKIP_GIT_SYNC", "1"),
        ("MAJADU_RC_CI_WAIT_ATTEMPTS", "1"),
        ("FAKE_CI_BODY", "not json")])
    check result.exitCode == 1
    check result.stdout.contains("empty or malformed response for abc1234")
    check not result.stdout.contains(
      "built localhost/majadu-rc-api:local")

  test "the CI gate refuses a commit with no ci.yml run":
    let fixture = newFixture("rc-ci-missing")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture)
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps-rc.sh"),
      @["badminton-match", "refs/heads/release/2.0.0-rc.1"],
      @[("MAJADU_RC_APP_DIR", rcDir), ("MAJADU_RC_SKIP_GIT_SYNC", "1"),
        ("MAJADU_RC_CI_WAIT_ATTEMPTS", "1"),
        ("FAKE_CI_BODY", ciMissingBody)])
    check result.exitCode == 1
    check result.stdout.contains(
      "no ci.yml run yet for abc1234 after 1 attempt(s)")
    check not result.stdout.contains(
      "built localhost/majadu-rc-api:local")

  test "the CI gate refuses while the run stays in progress":
    let fixture = newFixture("rc-ci-pending")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture)
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps-rc.sh"),
      @["badminton-match", "refs/heads/release/2.0.0-rc.1"],
      @[("MAJADU_RC_APP_DIR", rcDir), ("MAJADU_RC_SKIP_GIT_SYNC", "1"),
        ("MAJADU_RC_CI_WAIT_ATTEMPTS", "1"),
        ("FAKE_CI_BODY", ciPendingBody)])
    check result.exitCode == 1
    check result.stdout.contains(
      "the newest ci.yml run is in_progress for abc1234 after 1 attempt(s)")
    check not result.stdout.contains(
      "built localhost/majadu-rc-api:local")

  test "the CI gate waits for a queued run and builds when it passes":
    let fixture = newFixture("rc-ci-wait")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture)
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps-rc.sh"),
      @["badminton-match", "refs/heads/release/2.0.0-rc.1"],
      @[("MAJADU_RC_APP_DIR", rcDir), ("MAJADU_RC_SKIP_GIT_SYNC", "1"),
        ("MAJADU_RC_CI_WAIT_ATTEMPTS", "3"),
        ("MAJADU_RC_CI_WAIT_SECONDS", "0"),
        ("FAKE_CI_BODY", ciPendingBody),
        ("FAKE_CI_BODY_AFTER", ciSuccessBody),
        ("FAKE_CI_COUNTER", fixture.root / "ci-calls")])
    check result.stdout.contains(
      "waiting 0s (attempt 1/3, deploy lock held)")
    check result.stdout.contains("ci gate: abc1234 passed ci.yml")
    check result.stdout.contains(
      "built localhost/majadu-rc-api:local at abc1234")

  test "the CI gate fails closed on a network error":
    let fixture = newFixture("rc-ci-network")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture)
    let result = fixture.runShell(fixture.installOpsScript("deploy-vps-rc.sh"),
      @["badminton-match", "refs/heads/release/2.0.0-rc.1"],
      @[("MAJADU_RC_APP_DIR", rcDir), ("MAJADU_RC_SKIP_GIT_SYNC", "1"),
        ("MAJADU_RC_CI_WAIT_ATTEMPTS", "1"), ("FAKE_CI_EXIT", "22")])
    check result.exitCode == 1
    check result.stdout.contains(
      "cannot read ci.yml runs for abc1234 from api.github.com")
    check not result.stdout.contains(
      "built localhost/majadu-rc-api:local")

  test "the CI gate fails closed without a token":
    let fixture = newFixture("rc-ci-no-token")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture, token = false)
    let result = runRcGate(fixture, rcDir)
    check result.exitCode == 1
    check result.stdout.contains("has no token at " &
      rcDir / "env" / "github-token")
    check not result.stdout.contains(
      "built localhost/majadu-rc-api:local")

  test "the CI gate refuses a token that is not private":
    let fixture = newFixture("rc-ci-token-mode")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture)
    let tokenFile = rcDir / "env" / "github-token"
    setFilePermissions(tokenFile, {fpUserRead, fpUserWrite, fpGroupRead,
      fpOthersRead})
    let result = runRcGate(fixture, rcDir,
      @[("FAKE_CI_BODY", ciSuccessBody)])
    check result.exitCode == 1
    check result.stdout.contains(
      tokenFile & " must be mode 600 (found 644)")
    check not result.stdout.contains(
      "built localhost/majadu-rc-api:local")

  test "MAJADU_RC_SKIP_CI_GATE=1 bypasses the gate and is recorded":
    let fixture = newFixture("rc-ci-bypass")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture, token = false)
    let result = runRcGate(fixture, rcDir,
      @[("MAJADU_RC_SKIP_CI_GATE", "1")])
    check result.stdout.contains("WARNING: MAJADU_RC_SKIP_CI_GATE=1")
    check result.stdout.contains(
      "built localhost/majadu-rc-api:local at abc1234")
    # The run stops after the build in this fixture, and the failure record
    # still carries the bypass so the audit trail survives it.
    check readFile(rcDir / "deploy" / "last-release.json")
      .contains("\"ci\":\"bypassed\"")

  test "a redeploy of the live commit skips the gate without a token":
    let fixture = newFixture("rc-ci-live")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture, token = false)
    let curlLog = fixture.root / "curl.log"
    touch(rcDir / "deploy" / "last-release.json",
      "{\"version\":\"2.0.0\",\"commit\":\"abc1234\"}\n")
    let result = runRcGate(fixture, rcDir, @[("FAKE_CURL_LOG", curlLog)])
    check result.stdout.contains(
      "abc1234 is already the running release")
    check result.stdout.contains(
      "built localhost/majadu-rc-api:local at abc1234")
    # No lookup happened, so the fake curl never ran.
    check not fileExists(curlLog)

  test "an empty commit fails before the gate and the build":
    let fixture = newFixture("rc-ci-empty-commit")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture, token = false)
    # A git that answers nothing leaves COMMIT empty; the deploy must stop at
    # the commit check instead of querying head_sha= or building unlabelled.
    fixture.installFake("git", "#!/bin/sh\nexit 0\n")
    touch(rcDir / "deploy" / "last-release.json",
      "{\"version\":\"2.0.0\",\"commit\":\"\"}\n")
    let result = runRcGate(fixture, rcDir)
    check result.exitCode == 1
    check result.stdout.contains(
      "git rev-parse HEAD returned an empty commit")
    check not result.stdout.contains("already the running release")
    check not result.stdout.contains(
      "built localhost/majadu-rc-api:local")

  test "the CI gate refuses more than one page of runs":
    let fixture = newFixture("rc-ci-too-many")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture)
    let result = runRcGate(fixture, rcDir,
      @[("FAKE_CI_BODY", ciTooManyBody)])
    check result.exitCode == 1
    check result.stdout.contains("101 ci.yml runs for abc1234 exceed the 100-run page")
    check not result.stdout.contains(
      "built localhost/majadu-rc-api:local")

  test "the CI gate refuses when a run object cannot be parsed":
    let fixture = newFixture("rc-ci-partial")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture)
    let result = runRcGate(fixture, rcDir,
      @[("FAKE_CI_BODY", ciMissingRunNumberBody)])
    check result.exitCode == 1
    check result.stdout.contains(
      "parsed 1 of 2 ci.yml run objects for abc1234")
    check not result.stdout.contains(
      "built localhost/majadu-rc-api:local")

  test "the CI gate takes the highest id, not the first array element":
    let fixture = newFixture("rc-ci-order")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture)
    let result = runRcGate(fixture, rcDir,
      @[("FAKE_CI_BODY", ciOrderedBody)])
    check result.exitCode == 1
    check result.stdout.contains(
      "newest ci.yml run for abc1234 ended as failure")
    check not result.stdout.contains(
      "built localhost/majadu-rc-api:local")

  test "a signal during the CI wait leaves no token file behind":
    let fixture = newFixture("rc-ci-signal")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture)
    let script = fixture.installOpsScript("deploy-vps-rc.sh")
    let body = "bash " & quoteShell(script) &
      " badminton-match refs/heads/release/2.0.0-rc.1 & pid=$!; " &
      "sleep 3; kill -TERM $pid 2>/dev/null; wait $pid 2>/dev/null; exit 0"
    let driver = fixture.root / "signal-driver.sh"
    writeFile(driver, "#!/bin/sh\n" & body & "\n")
    setFilePermissions(driver, {fpUserRead, fpUserWrite, fpUserExec})
    let result = fixture.runShell(driver, @[],
      @[("MAJADU_RC_APP_DIR", rcDir), ("MAJADU_RC_SKIP_GIT_SYNC", "1"),
        ("FAKE_CI_BODY", ciPendingBody),
        ("MAJADU_RC_CI_WAIT_ATTEMPTS", "100"),
        ("MAJADU_RC_CI_WAIT_SECONDS", "1")])
    check result.exitCode == 0
    # The signal has to land while the gate is waiting, otherwise the case
    # proves nothing.
    check result.stdout.contains("waiting 1s")
    for kind, path in walkDir(rcDir / "deploy"):
      check not path.extractFilename.startsWith("ci-auth")

  test "the token never appears in an xtrace":
    let fixture = newFixture("rc-ci-xtrace")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture)
    let script = fixture.installOpsScript("deploy-vps-rc.sh")
    let driver = fixture.root / "xtrace-driver.sh"
    writeFile(driver, "#!/bin/sh\nexec bash -x " & quoteShell(script) &
      " badminton-match refs/heads/release/2.0.0-rc.1\n")
    setFilePermissions(driver, {fpUserRead, fpUserWrite, fpUserExec})
    let result = fixture.runShell(driver, @[],
      @[("MAJADU_RC_APP_DIR", rcDir), ("MAJADU_RC_SKIP_GIT_SYNC", "1"),
        ("MAJADU_RC_CI_WAIT_ATTEMPTS", "1"),
        ("FAKE_CI_BODY", ciSuccessBody)])
    # The gate ran and read the token, and the trace kept its value out.
    check result.stdout.contains("ci gate: abc1234 passed ci.yml")
    check not result.stdout.contains("secret-token")
    check not result.stderr.contains("secret-token")

  test "an owner DSN left in the RC API env stops the deploy":
    let fixture = newFixture("rc-api-env-owner")
    defer: removeDir(fixture.root)
    let rcDir = rcGateFixture(fixture)
    let envFile = rcDir / "env" / "majadu-rc.env"
    let toolsFile = rcDir / "env" / "majadu-rc-tools.env"
    privateFile(envFile,
      "MAJADU_PG_DSN=postgres://bm2_app@127.0.0.1:5432/bm2_rc\n" &
      "MAJADU_OWNER_DSN=postgres://bm2_owner@127.0.0.1:5432/bm2_rc\n")
    let result = runRcGate(fixture, rcDir)
    check result.exitCode == 1
    check result.stdout.contains(
      envFile & " must not contain MAJADU_OWNER_DSN; move it to " & toolsFile)
    check not result.stdout.contains("built localhost/majadu-rc-api:local")

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
    # The maintenance step succeeds; the Caddy check in the next one fails, so
    # the ERR trap has to fire inside the step function and stop the sequence.
    let result = fixture.runShell(fixture.installOpsScript("cutover.sh"),
      @["--version", "2.0.0", "--from", "maintenance"], appDir(fixture) & @[
        ("MAJADU_CADDY_VALIDATE", "false"),
      ])
    check result.exitCode == 1
    check result.stdout.contains("ERROR: command failed at line")
    check result.stdout.contains("(step: maintenance)")
    check result.stdout.contains("last step: maintenance")
    check not result.stdout.contains("v1 is stopped and disabled")
    check not result.stdout.contains("cutover sequence finished")
    check readFile(fixture.root / "cutover" / "cutover.step")
      .contains("\"state\":\"failed\"")

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

  test "the abandoned-row guard is skipped without an owner DSN":
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
    check result.exitCode == 0
    check result.stdout.contains("rollback complete")
    check result.stdout.contains(
      "WARNING: no owner DSN available; the abandoned-row guard will be skipped")
    check not fileExists(psqlLog)

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
      "ERROR: 3 row(s) were written to v2 since the cutover; rollback discards them. " &
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

  test "a Caddy reload failure ends with v1 running and one alert":
    let fixture = newFixture("rollback-caddy")
    defer: removeDir(fixture.root)
    simFakes(fixture)
    let systemctlLog = fixture.root / "systemctl.log"
    fixture.installFake("systemctl", systemctlLogFake)
    createDir(fixture.root / "caddy")
    let result = fixture.runShell(fixture.installOpsScript("rollback.sh"),
      @[], appDir(fixture) & @[
        ("MAJADU_CADDY_VALIDATE", "true"),
        ("MAJADU_CADDY_RELOAD", "false"),
        ("FAKE_SYSTEMCTL_LOG", systemctlLog),
      ])
    check result.exitCode != 0
    let rollbackLog = readFile(fixture.root / "logs" / "rollback.log")
    # The service is back before Caddy is touched, and the failure names the
    # state the site is left in.
    check rollbackLog.contains("v1 answers /healthz")
    check rollbackLog.contains("ERROR: Caddy reload failed")
    check rollbackLog.find("v1 answers /healthz") <
      rollbackLog.find("ERROR: Caddy reload failed")
    let calls = readFile(systemctlLog)
    check calls.contains("restart majadu-api")
    check calls.contains("start majadu-alert@rollback.service")

suite "bootstrap-rc.sh":
  test "a missing env file is refused":
    let fixture = newFixture("bootstrap-no-env")
    defer: removeDir(fixture.root)
    let rcDir = fixture.root / "rc"
    let result = fixture.runShell(fixture.installOpsScript("bootstrap-rc.sh"),
      @[], @[("MAJADU_RC_APP_DIR", rcDir)])
    check result.exitCode == 1
    check result.stderr.contains(rcDir / "env" / "majadu-rc.env" &
      " is missing; copy ops/env/rc.env.example and fill it in")

  test "an env file that is not private is refused":
    let fixture = newFixture("bootstrap-mode")
    defer: removeDir(fixture.root)
    let rcDir = fixture.root / "rc"
    let envFile = rcDir / "env" / "majadu-rc.env"
    touch(envFile, "MAJADU_PG_DSN=x\n")
    setFilePermissions(envFile, {fpUserRead, fpUserWrite, fpGroupRead,
      fpOthersRead})
    privateFile(rcDir / "env" / "majadu-rc-tools.env",
      "MAJADU_OWNER_DSN=x\n")
    let result = fixture.runShell(fixture.installOpsScript("bootstrap-rc.sh"),
      @[], @[("MAJADU_RC_APP_DIR", rcDir)])
    check result.exitCode == 1
    check result.stderr.contains(
      envFile & " must be mode 600 (found 644)")

  test "an env file without either DSN is refused":
    let fixture = newFixture("bootstrap-dsn")
    defer: removeDir(fixture.root)
    let rcDir = fixture.root / "rc"
    let envFile = rcDir / "env" / "majadu-rc.env"
    let toolsFile = rcDir / "env" / "majadu-rc-tools.env"
    privateFile(envFile,
      "MAJADU_PG_DSN=postgres://bm2_app:secret@127.0.0.1:5432/bm2_rc\n")
    privateFile(toolsFile, "MAJADU_OWNER_DSN=\n")
    let script = fixture.installOpsScript("bootstrap-rc.sh")
    let noOwner = fixture.runShell(script, @[],
      @[("MAJADU_RC_APP_DIR", rcDir)])
    check noOwner.exitCode == 1
    check noOwner.stderr.contains("MAJADU_OWNER_DSN is missing from " & toolsFile)
    privateFile(envFile, "MAJADU_PG_DSN=\n")
    privateFile(toolsFile,
      "MAJADU_OWNER_DSN=postgres://bm2_owner@127.0.0.1:5432/bm2_rc\n")
    let noApp = fixture.runShell(script, @[],
      @[("MAJADU_RC_APP_DIR", rcDir)])
    check noApp.exitCode == 1
    check noApp.stderr.contains("MAJADU_PG_DSN is missing from " & envFile)

  test "a live database name is refused":
    let fixture = newFixture("bootstrap-live-db")
    defer: removeDir(fixture.root)
    let rcDir = fixture.root / "rc"
    let envFile = rcDir / "env" / "majadu-rc.env"
    let script = fixture.installOpsScript("bootstrap-rc.sh")
    # A bogus `.git` keeps a run that slips past the allowlist inside the
    # fixture instead of cloning the repository.
    createDir(rcDir / "repo" / ".git")
    for name in ["bm", "bm2", "majadu", "postgres"]:
      privateFile(envFile,
        "MAJADU_PG_DSN=postgres://bm2_app:secret@127.0.0.1:5432/" & name & "\n")
      privateFile(rcDir / "env" / "majadu-rc-tools.env",
        "MAJADU_OWNER_DSN=postgres://bm2_owner:secret@127.0.0.1:5432/" & name & "\n")
      let result = fixture.runShell(script, @[],
        @[("MAJADU_RC_APP_DIR", rcDir)])
      check result.exitCode == 1
      check result.stderr.contains("refusing to bootstrap over '" & name &
        "'; use a dedicated RC database")

  test "an existing bm2 database stops the run before the checkout":
    let fixture = newFixture("bootstrap-bm2-exists")
    defer: removeDir(fixture.root)
    let rcDir = fixture.root / "rc"
    privateFile(rcDir / "env" / "majadu-rc.env",
      "MAJADU_PG_DSN=postgres://bm2_app:secret@127.0.0.1:5432/bm2_rc\n")
    privateFile(rcDir / "env" / "majadu-rc-tools.env",
      "MAJADU_OWNER_DSN=postgres://bm2_owner:secret@127.0.0.1:5432/bm2_rc\n")
    let podmanLog = fixture.root / "podman.log"
    fixture.installFake("podman", podmanFake)
    let result = fixture.runShell(fixture.installOpsScript("bootstrap-rc.sh"),
      @[], @[("MAJADU_RC_APP_DIR", rcDir), ("FAKE_BM2_EXISTS", "1"),
        ("FAKE_PODMAN_LOG", podmanLog)])
    check result.exitCode == 1
    check result.stderr.contains(
      "database bm2 exists; this script would reset the production role passwords. " &
      "Dismantle the RC or give it dedicated roles first.")
    check not fileExists(rcDir / "repo" / "VERSION")

  test "a verified RC database exits 0 with the pass --force message":
    let fixture = newFixture("bootstrap-verified")
    defer: removeDir(fixture.root)
    let rcDir = fixture.root / "rc"
    privateFile(rcDir / "env" / "majadu-rc.env",
      "MAJADU_PG_DSN=postgres://bm2_app:secret@127.0.0.1:5432/bm2_rc\n")
    privateFile(rcDir / "env" / "majadu-rc-tools.env",
      "MAJADU_OWNER_DSN=postgres://bm2_owner:secret@127.0.0.1:5432/bm2_rc\n")
    touch(rcDir / "repo" / "VERSION", "2.0.0\n")
    let podmanLog = fixture.root / "podman.log"
    fixture.installFake("podman", podmanFake)
    fixture.installFake("git", gitFake)
    let result = fixture.runShell(fixture.installOpsScript("bootstrap-rc.sh"),
      @[], @[("MAJADU_RC_APP_DIR", rcDir), ("FAKE_PODMAN_LOG", podmanLog)])
    check result.exitCode == 0
    check result.stdout.contains(
      "bm2_rc already carries the RC schema; pass --force to drop and rebuild it")
    check not readFile(podmanLog).contains("drop database")

  test "--force drops the verified RC database":
    let fixture = newFixture("bootstrap-force")
    defer: removeDir(fixture.root)
    let rcDir = fixture.root / "rc"
    privateFile(rcDir / "env" / "majadu-rc.env",
      "MAJADU_PG_DSN=postgres://bm2_app:secret@127.0.0.1:5432/bm2_rc\n")
    privateFile(rcDir / "env" / "majadu-rc-tools.env",
      "MAJADU_OWNER_DSN=postgres://bm2_owner:secret@127.0.0.1:5432/bm2_rc\n")
    touch(rcDir / "repo" / "VERSION", "2.0.0\n")
    let podmanLog = fixture.root / "podman.log"
    fixture.installFake("podman", podmanFake)
    fixture.installFake("git", gitFake)
    let result = fixture.runShell(fixture.installOpsScript("bootstrap-rc.sh"),
      @["--force"], @[("MAJADU_RC_APP_DIR", rcDir),
        ("FAKE_PODMAN_LOG", podmanLog)])
    # Nothing in the fixture knows a source database, so the run stops before
    # the copy; the case is about the drop that --force performs after verify.
    check result.exitCode != 0
    check result.stdout.contains("dropping bm2_rc")
    check readFile(podmanLog).contains(
      "drop database if exists bm2_rc with (force)")
suite "systemd units":
  # A macOS checkout cannot run systemd, so these cases read the unit files as
  # the deploy script installs them. The host-side proof is
  # `systemd-analyze verify` after a deploy; that is documented in
  # docs/ops/operations.md.
  let unitsDir = repoDir / "ops" / "systemd"

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

  test "the RC deploy installs the alert template":
    let script = readFile(opsScriptsDir / "deploy-vps-rc.sh")
    check script.contains("ops/systemd/majadu-alert@.service")
    check script.contains("$HOME/.config/systemd/user/majadu-alert@.service")
    check script.contains("install -m 644 \"$ALERT_SRC\" \"$ALERT_DEST\"")

  test "the API unit loads an env file without any tool DSN":
    var envPath = ""
    for line in readFile(unitsDir / "majadu-api.container").splitLines:
      if line.startsWith("EnvironmentFile="):
        envPath = line.split("=", maxsplit = 1)[1]
    check envPath == "/srv/qouver/apps/majadu/env/majadu-prod.env"
    let apiEnv = readFile(repoDir / "ops" / "env" / "prod.env.example")
    let toolsEnv = readFile(repoDir / "ops" / "env" / "prod-tools.env.example")
    check apiEnv.contains("MAJADU_PG_DSN=")
    for key in ["MAJADU_OWNER_DSN=", "MAJADU_ETL_DSN=",
                "MAJADU_ETL_SOURCE_DSN=", "MAJADU_CUTOVER_RESTORE_DSN=",
                "MAJADU_AUDIT_DSN="]:
      check not apiEnv.contains(key)
      check toolsEnv.contains(key)

  test "the RC API unit loads an env file without the owner DSN":
    var envPath = ""
    for line in readFile(unitsDir / "majadu-rc-api.container").splitLines:
      if line.startsWith("EnvironmentFile="):
        envPath = line.split("=", maxsplit = 1)[1]
    check envPath == "/srv/qouver/apps/majadu-rc/env/majadu-rc.env"
    let apiEnv = readFile(repoDir / "ops" / "env" / "rc.env.example")
    check apiEnv.contains("MAJADU_PG_DSN=")
    check not apiEnv.contains("MAJADU_OWNER_DSN=")
    let toolsEnv = readFile(repoDir / "ops" / "env" / "rc-tools.env.example")
    check toolsEnv.contains("MAJADU_OWNER_DSN=")
