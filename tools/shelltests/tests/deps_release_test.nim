# SEC-05: a scanner that only CI downloads cannot be hashed on this machine, so
# the `release:` entry is a pin the workflow has to agree with. These cases fix
# that agreement in both directions: the lock cannot carry a digest nobody uses,
# and a workflow cannot download a different file.

import std/[os, strutils, unittest]
import ../harness

const
  url = "https://example.invalid/v2.7.0/osv-scanner_linux_amd64"
  digest = "160c6253e2922e9e0a6a9771c5c4c40a4b3c6090b34a3cdd5e80c96cc2e4218b"
  other = "0000000000000000000000000000000000000000000000000000000000000001"
  entry = "osv-scanner 2.7.0 release:" & url & " " & digest & "\n"

proc seed(fixture: Fixture, body: string) =
  ## The lock starts without a tree line: the first `--print` run supplies the
  ## one the entry resolves to, which keeps the case about the resolver.
  writeFile(fixture.root / "deps.lock", body)
  createDir(fixture.root / ".github" / "workflows")

proc workflow(binaryDigest: string): string =
  "jobs:\n  scan:\n    steps:\n" &
    "      - name: \"Install: pinned scanner\"\n" &
    "        env:\n" &
    "          OSV_URL: " & url & "\n" &
    "          OSV_SHA256: " & binaryDigest & "\n" &
    "        run: echo install\n"

proc freezeTree(fixture: Fixture) =
  ## Copy the tree line `--print` computes into the lock, so the happy case is
  ## green for the reason under test and not because the tree was skipped.
  let printed = fixture.runTask(@["deps-check", "--print"])
  for line in printed.stdout.splitLines:
    if line.startsWith("tree "):
      writeFile(fixture.root / "deps.lock",
        line & "\n" & readFile(fixture.root / "deps.lock"))
      return

suite "deps-check release pins":
  test "a workflow that verifies the recorded digest passes":
    let fixture = newFixture("deps-release-ok")
    defer: removeDir(fixture.root)
    fixture.seed("tree " & "0".repeat(64) & "\n" & entry)
    writeFile(fixture.root / ".github" / "workflows" / "ci.yml",
      workflow(digest))
    fixture.freezeTree()
    let result = fixture.runTask(@["deps-check"])
    check result.exitCode == 0
    check result.stdout.contains("deps-check: ok")

  test "a workflow that downloads a different file fails":
    let fixture = newFixture("deps-release-drift")
    defer: removeDir(fixture.root)
    fixture.seed("tree " & "0".repeat(64) & "\n" & entry)
    writeFile(fixture.root / ".github" / "workflows" / "ci.yml",
      workflow(other))
    fixture.freezeTree()
    let result = fixture.runTask(@["deps-check"])
    check result.exitCode == 1
    check result.stderr.contains("entry differs: osv-scanner")

  test "a download nobody performs fails":
    let fixture = newFixture("deps-release-missing")
    defer: removeDir(fixture.root)
    fixture.seed("tree " & "0".repeat(64) & "\n" & entry)
    let result = fixture.runTask(@["deps-check"])
    check result.exitCode == 1
    check result.stderr.contains("no workflow downloads " & url)

  test "a download with no recorded checksum fails":
    let fixture = newFixture("deps-release-nodigest")
    defer: removeDir(fixture.root)
    fixture.seed("tree " & "0".repeat(64) & "\n" & entry)
    writeFile(fixture.root / ".github" / "workflows" / "ci.yml",
      workflow("").replace("OSV_SHA256: \n", ""))
    let result = fixture.runTask(@["deps-check"])
    check result.exitCode == 1
    check result.stderr.contains("downloads " & url & " with no 64-hex sha256")

  test "two workflows that disagree fail":
    let fixture = newFixture("deps-release-disagree")
    defer: removeDir(fixture.root)
    fixture.seed("tree " & "0".repeat(64) & "\n" & entry)
    writeFile(fixture.root / ".github" / "workflows" / "ci.yml",
      workflow(digest))
    writeFile(fixture.root / ".github" / "workflows" / "nightly.yml",
      workflow(other))
    let result = fixture.runTask(@["deps-check"])
    check result.exitCode == 1
    check result.stderr.contains("workflows disagree on the sha256")
