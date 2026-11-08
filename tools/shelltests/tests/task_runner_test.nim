import std/[os, strutils, unittest]
import ../harness

const dumpEnv = """#!/bin/sh
printf '%s\n' "$WORKTREE"
printf '%s\n' "$NIMCACHE_CHECK"
printf '%s\n' "$NIMCACHE_BUILD"
"""

proc addDumpEnvTarget(fixture: Fixture) =
  writeExecutable(fixture.root / "task.d" / "dumpenv.sh", dumpEnv)

proc hex8(value: string): bool =
  value.len == 8 and value.allCharsInSet({'0'..'9', 'a'..'f'})

suite "task runner":
  test "no target prints usage and exits 2":
    let fixture = newFixture("task-no-target")
    defer: removeDir(fixture.root)
    let result = fixture.runTask()
    check result.exitCode == 2
    check result.stdout.contains("Usage: ./task <target> [args...]")
    check result.stdout.contains("Targets:")
    check result.stderr.len == 0

  test "help exits 0 and prints usage":
    let fixture = newFixture("task-help")
    defer: removeDir(fixture.root)
    for target in ["help", "-h", "--help"]:
      let result = fixture.runTask(@[target])
      check result.exitCode == 0
      check result.stdout.contains("Usage: ./task <target> [args...]")
      check result.stderr.len == 0

  test "unknown target reports on stderr and exits 2":
    let fixture = newFixture("task-unknown")
    defer: removeDir(fixture.root)
    let result = fixture.runTask(@["nosuchtarget"])
    check result.exitCode == 2
    check result.stderr.contains("Unknown target: nosuchtarget")
    check result.stderr.contains("Usage: ./task <target> [args...]")
    check result.stdout.len == 0

  test "cache paths live under the root and stay stable across runs":
    let fixture = newFixture("task-cache")
    defer: removeDir(fixture.root)
    addDumpEnvTarget(fixture)
    let first = fixture.runTask(@["dumpenv"])
    check first.exitCode == 0
    let lines = parseLines(first.stdout)
    check lines.len == 3
    let worktree = lines[0]
    check worktree.len >= 10
    check worktree[^9] == '-'
    check hex8(worktree[^8 .. ^1])
    check lines[1] == fixture.root / ".cache" / worktree / "check"
    check lines[2] == fixture.root / ".cache" / worktree / "build"
    check dirExists(lines[1])
    check dirExists(lines[2])
    let second = fixture.runTask(@["dumpenv"])
    check parseLines(second.stdout)[0] == worktree

  test "two repository roots never share a worktree":
    let first = newFixture("task-root-a")
    defer: removeDir(first.root)
    let second = newFixture("task-root-b")
    defer: removeDir(second.root)
    addDumpEnvTarget(first)
    addDumpEnvTarget(second)
    let a = first.runTask(@["dumpenv"])
    let b = second.runTask(@["dumpenv"])
    check a.exitCode == 0
    check b.exitCode == 0
    let worktreeA = parseLines(a.stdout)[0]
    let worktreeB = parseLines(b.stdout)[0]
    check worktreeA != worktreeB
    check parseLines(a.stdout)[1] != parseLines(b.stdout)[1]