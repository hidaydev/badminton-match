import std/[os, osproc, strutils, unittest]
import ../harness

proc gitRun(root: string, args: seq[string]) =
  let process = startProcess("git", workingDir = root, args = args,
    options = {poUsePath})
  doAssert process.waitForExit() == 0
  process.close()

proc initRepo(root: string) =
  gitRun(root, @["init", "-q", "-b", "main"])
  gitRun(root, @["config", "user.name", "Release Guard"])
  gitRun(root, @["config", "user.email", "release-guard@example.invalid"])
  gitRun(root, @["config", "commit.gpgsign", "false"])
  gitRun(root, @["config", "tag.gpgSign", "false"])
  gitRun(root, @["add", "-A"])
  gitRun(root, @["commit", "-q", "-m", "chore: fixture"])

suite "release ancestry guard":
  test "a divergent release branch cannot prepare a release":
    let fixture = newFixture("release-diverged")
    defer: removeDir(fixture.root)
    initRepo(fixture.root)
    gitRun(fixture.root, @["checkout", "-q", "-b", "release"])
    writeFile(fixture.root / "release.txt", "r\n")
    gitRun(fixture.root, @["add", "-A"])
    gitRun(fixture.root, @["commit", "-q", "-m", "fix: release work"])
    gitRun(fixture.root, @["checkout", "-q", "main"])
    writeFile(fixture.root / "main.txt", "m\n")
    gitRun(fixture.root, @["add", "-A"])
    gitRun(fixture.root, @["commit", "-q", "-m", "feat: main work"])
    gitRun(fixture.root, @["checkout", "-q", "release"])
    let result = fixture.runTask(@["release"])
    check result.exitCode == 1
    check result.stderr.contains("does not contain main")

  test "a release branch that already contains main reaches the tool":
    let fixture = newFixture("release-contained")
    defer: removeDir(fixture.root)
    check dirExists(fixture.root)
    initRepo(fixture.root)
    gitRun(fixture.root, @["checkout", "-q", "-b", "release"])
    writeFile(fixture.root / "release.txt", "r\n")
    gitRun(fixture.root, @["add", "-A"])
    gitRun(fixture.root, @["commit", "-q", "-m", "fix: release work"])
    let result = fixture.runTask(@["release"])
    # The fake `nim` writes a no-op binary and the tool runs it, so reaching
    # the tool is exit 0; the guard would have failed before that.
    check result.exitCode == 0
    check not result.stderr.contains("does not contain main")
