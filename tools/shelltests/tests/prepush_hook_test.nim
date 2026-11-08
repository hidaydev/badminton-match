## The pre-push hook is the last defence against publishing internal audits and
## review notes: the history was rewritten once (T-108) and this hook keeps it
## that way. It reads a git tree, so every case builds its own small repository.
##
## `./task hooks` is checked here too, against a temporary repository: it writes
## `core.hooksPath`, and the real repository's setting must not be touched by a
## test run.

import std/[os, osproc, strtabs, strutils, unittest]

proc run(command, cwd: string): tuple[output: string, status: int] =
  var environment = newStringTable(modeCaseSensitive)
  for (key, value) in envPairs():
    environment[key] = value
  let outcome = execCmdEx(command, workingDir = cwd, env = environment)
  (output: outcome.output, status: outcome.exitCode)

proc git(repository, arguments: string): tuple[output: string, status: int] =
  run("git " & arguments, repository)

proc epochTimeInt(): int =
  ## A per-call suffix, without depending on the clock module: two repositories
  ## created in the same second must not collide.
  var counter {.global.}: int
  inc counter
  result = counter

proc newRepository(): string =
  ## A repository with one commit and no hooks installed. The hook itself is
  ## copied in by `installHook`, because the temp repo has no `.githooks`.
  result = getTempDir() / ("majadu-prepush-" & $getCurrentProcessId() & "-" &
    $epochTimeInt())
  createDir(result)
  discard git(result, "init --quiet")
  discard git(result, "config user.name 'Hook Test'")
  discard git(result, "config user.email 'hook@example.com'")
  discard git(result, "config commit.gpgsign false")

proc installHook(repository, hookSource: string): string =
  let hooks = repository / ".githooks"
  createDir(hooks)
  result = hooks / "pre-push"
  copyFile(hookSource, result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc commit(repository, relative: string) =
  let absolute = repository / relative
  createDir(absolute.parentDir)
  writeFile(absolute, "content\n")
  discard git(repository, "add -A")
  discard git(repository, "commit --quiet -m 'add " & relative & "'")

proc hookPath(): string =
  ## The hook lives in the tree under test, not in a copy: a change to the hook
  ## must be able to break its own case.
  const fromSource = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  result = fromSource / ".githooks" / "pre-push"
  if not fileExists(result):
    result = getCurrentDir() / ".githooks" / "pre-push"

proc hooksScript(): string =
  const fromSource = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  result = fromSource / "task.d" / "hooks.sh"
  if not fileExists(result):
    result = getCurrentDir() / "task.d" / "hooks.sh"

suite "pre-push hook":
  test "an audit file that reached HEAD is rejected with its path and the fix":
    let repository = newRepository()
    try:
      let hook = installHook(repository, hookPath())
      commit(repository, "docs/audits/2026-11-08.md")
      let run = run(quoteShell(hook), repository)
      check run.status == 1
      check run.output.contains("docs/audits/2026-11-08.md")
      check run.output.contains(".local/audits")
    finally:
      removeDir(repository)

  test "a plan review file is rejected the same way":
    let repository = newRepository()
    try:
      let hook = installHook(repository, hookPath())
      commit(repository, "docs/plan/reviews/x.md")
      let run = run(quoteShell(hook), repository)
      check run.status == 1
      check run.output.contains("docs/plan/reviews/x.md")
      check run.output.contains(".local/plan-reviews")
    finally:
      removeDir(repository)

  test "a clean tree passes":
    let repository = newRepository()
    try:
      let hook = installHook(repository, hookPath())
      commit(repository, "docs/handbook/current-status.md")
      let run = run(quoteShell(hook), repository)
      check run.status == 0
      check not run.output.contains("belong in .local/")
    finally:
      removeDir(repository)

suite "hooks target":
  test "installs core.hooksPath and is idempotent":
    let repository = newRepository()
    try:
      var environment = newStringTable(modeCaseSensitive)
      for (key, value) in envPairs():
        environment[key] = value
      environment["REPO_ROOT"] = repository
      environment["WORKTREE"] = "shelltest"
      environment["NIMCACHE_CHECK"] = repository / ".cache" / "check"
      environment["NIMCACHE_BUILD"] = repository / ".cache" / "build"

      let first = execCmdEx(quoteShell(hooksScript()), env = environment)
      check first.exitCode == 0
      check first.output.contains("core.hooksPath=.githooks")
      check git(repository, "config --get core.hooksPath").output.strip() ==
        ".githooks"

      let second = execCmdEx(quoteShell(hooksScript()), env = environment)
      check second.exitCode == 0
      check git(repository, "config --get core.hooksPath").output.strip() ==
        ".githooks"
    finally:
      removeDir(repository)