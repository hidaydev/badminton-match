# SEC-03: the tag signature is only as trustworthy as the key list behind it.
# The release workflow used to fall back to "GitHub says some key on the
# maintainer account signed this", which is a trust decision made by whoever can
# add a key to that account. `.github/allowed_signers` is the committed anchor,
# and `--release` refuses a tree without one instead of discovering that at tag
# time.

import std/[os, strutils, unittest]
import ../harness

const minimalWorkflow = """name: CI
on: push
jobs:
  gate:
    name: "Gate"
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
"""

proc prepare(fixture: Fixture): string =
  createDir(fixture.root / ".github" / "workflows")
  writeFile(fixture.root / ".github" / "workflows" / "ci.yml", minimalWorkflow)
  fixture.root / ".github" / "allowed_signers"

suite "release trust anchor":
  test "a release without allowed_signers is refused":
    let fixture = newFixture("anchor-missing")
    defer: removeDir(fixture.root)
    discard fixture.prepare()
    let result = fixture.runTask(@["ci-guards", "--release"])
    check result.exitCode == 1
    check result.stderr.contains("missing .github/allowed_signers")

  test "a release with only comments in it is refused":
    let fixture = newFixture("anchor-comments")
    defer: removeDir(fixture.root)
    let signers = fixture.prepare()
    writeFile(signers, "# the release key lands here\n\n")
    let result = fixture.runTask(@["ci-guards", "--release"])
    check result.exitCode == 1
    check result.stderr.contains("has no key line")

  test "a release with a key line passes":
    let fixture = newFixture("anchor-present")
    defer: removeDir(fixture.root)
    let signers = fixture.prepare()
    writeFile(signers,
      "release@example.invalid ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixture\n")
    let result = fixture.runTask(@["ci-guards", "--release"])
    check result.exitCode == 0
    check result.stdout.contains("ci-guards: ok")

  test "a pull request tree is not held to the release anchor":
    let fixture = newFixture("anchor-pull-request")
    defer: removeDir(fixture.root)
    discard fixture.prepare()
    let result = fixture.runTask(@["ci-guards"])
    check result.exitCode == 0
    check result.stdout.contains("ci-guards: ok")
