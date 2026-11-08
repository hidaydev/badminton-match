# Shell test harness for the task runner (TL-18).
#
# Every case builds a disposable repository root: `task`, `task.d/` and a fake
# `PATH` holding `nim`, `psql`, `podman` and `systemctl`. The scripts under test
# run there, so no case writes inside the checkout, the developer cache or
# `$HOME`.

import std/[os, osproc, streams, strtabs, strutils, tempfiles]

const repoDir* = currentSourcePath().parentDir.parentDir.parentDir
const opsScriptsDir* = repoDir / "ops" / "scripts"

const fakeNim* = """#!/bin/sh
out=
for arg in "$@"; do
  case "$arg" in
    -o:*) out=${arg#-o:} ;;
  esac
done
if [ -n "$out" ]; then
  mkdir -p "$(dirname "$out")"
  printf '#!/bin/sh\nexit 0\n' >"$out"
  chmod +x "$out"
fi
exit 0
"""

const execOk* = """#!/bin/sh
exit 0
"""

type
  ShellResult* = object
    exitCode*: int
    stdout*: string
    stderr*: string

  Fixture* = ref object
    root*: string
    binDir*: string
    env*: StringTableRef

proc writeExecutable*(path, body: string) =
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc newFixture*(name: string): Fixture =
  ## Creates the temp root, the fake binaries and the minimal repository tree.
  let root = expandFilename(createTempDir("tl18-" & name & "-", ""))
  let binDir = root / "fakebin"
  createDir(binDir)
  writeExecutable(binDir / "nim", fakeNim)
  for stub in ["psql", "podman", "systemctl"]:
    writeExecutable(binDir / stub, execOk)

  copyFile(repoDir / "task", root / "task")
  copyDir(repoDir / "task.d", root / "task.d")

  for dir in ["apps", "modules", "shared", "tools"]:
    createDir(root / dir)
  createDir(root / "docs" / "handbook")
  writeFile(root / "docs" / "handbook" / "flaky-tests.json",
    "{\"test\": \"example\", \"owner\": \"TL-18\", \"firstSeen\": \"2026-01-01\", " &
    "\"expires\": \"2099-01-01\", \"issue\": \"https://example.invalid/1\"}\n")

  let home = root / "home"
  let tmp = root / "tmp"
  createDir(home)
  createDir(tmp)
  let env = newStringTable(modeCaseSensitive)
  # Only the system utilities the scripts need, never the developer's PATH, and
  # never a MAJADU_* variable that could leak in from the caller.
  env["PATH"] = binDir & ":/usr/bin:/bin:/usr/sbin:/sbin"
  env["HOME"] = home
  env["TMPDIR"] = tmp
  env["LC_ALL"] = "C"

  Fixture(root: root, binDir: binDir, env: env)

proc runShell*(fixture: Fixture, script: string, args: seq[string] = @[],
    extraEnv: seq[(string, string)] = @[],
    unsetEnv: seq[string] = @[],
    workingDir: string = ""): ShellResult =
  ## Runs `/bin/sh <script> <args...>` with the fixture environment.
  var env = newStringTable(modeCaseSensitive)
  for key, value in fixture.env:
    env[key] = value
  for (key, value) in extraEnv:
    env[key] = value
  for key in unsetEnv:
    env.del(key)
  let cwd = if workingDir.len > 0: workingDir else: fixture.root
  let process = startProcess("/bin/sh", workingDir = cwd,
    args = @[script] & args, env = env, options = {})
  result.stdout = process.outputStream.readAll()
  result.stderr = process.errorStream.readAll()
  result.exitCode = process.waitForExit()
  process.close()

proc runTask*(fixture: Fixture, args: seq[string] = @[],
    extraEnv: seq[(string, string)] = @[],
    unsetEnv: seq[string] = @[]): ShellResult =
  fixture.runShell(fixture.root / "task", args, extraEnv, unsetEnv)

proc runLib*(fixture: Fixture, body: string,
    extraEnv: seq[(string, string)] = @[],
    unsetEnv: seq[string] = @[]): ShellResult =
  ## Sources task.d/lib.sh, then runs `body`. `$1` inside `body` is lib.sh.
  let worktree = "tl18-wt"
  var env = @[
    ("REPO_ROOT", fixture.root),
    ("WORKTREE", worktree),
    ("NIMCACHE_CHECK", fixture.root / ".cache" / worktree / "check"),
    ("NIMCACHE_BUILD", fixture.root / ".cache" / worktree / "build"),
  ]
  env.add(extraEnv)
  fixture.runShell("-c", @[body, "sh", fixture.root / "task.d" / "lib.sh"],
    env, unsetEnv)

proc parseLines*(output: string): seq[string] =
  for line in output.splitLines:
    if line.len > 0:
      result.add(line)

proc installOpsScript*(fixture: Fixture, name: string): string {.discardable.} =
  ## Copies one shipping `ops/scripts/<name>` into the fixture tree and returns
  ## the copy. Scripts that run their siblings (a dispatch target, for example)
  ## then resolve those siblings inside the fixture, not in the checkout.
  let dest = fixture.root / "ops" / "scripts" / name
  createDir(dest.parentDir)
  copyFile(opsScriptsDir / name, dest)
  setFilePermissions(dest, {fpUserRead, fpUserWrite})
  dest

proc installFake*(fixture: Fixture, name, body: string): string {.discardable.} =
  ## Adds one more fake program to the fixture PATH and returns its path.
  let path = fixture.binDir / name
  writeExecutable(path, body)
  path