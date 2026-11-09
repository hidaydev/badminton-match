# OPS-19: the CI contract that is not enforced by running the pipeline.
#
# The workflows are read as files, because a checkout on macOS cannot run
# GitHub Actions. The cases cover the two properties a future edit silently
# drops: every job keeps the 15-minute cap, and ci.yml keeps its concurrency
# group, its compiler cache and the Coverage dependency in the gate.

import std/[os, strutils, unittest]
import ../harness

proc installWorkflows(fixture: Fixture): string =
  let dest = fixture.root / ".github" / "workflows"
  createDir(dest)
  for kind, path in walkDir(repoDir / ".github" / "workflows"):
    if kind == pcFile:
      copyFile(path, dest / path.extractFilename)
  dest

suite "workflow contract":
  test "every job in the committed workflows declares the 15-minute cap":
    let fixture = newFixture("workflow-timeout-ok")
    defer: removeDir(fixture.root)
    discard installWorkflows(fixture)
    let result = fixture.runTask(@["ci-guards"])
    check result.exitCode == 0
    check result.stdout.contains("ci-guards: ok")

  test "a job without the cap fails the guard and names it":
    let fixture = newFixture("workflow-timeout-missing")
    defer: removeDir(fixture.root)
    let workflows = installWorkflows(fixture)
    let ci = workflows / "ci.yml"
    let text = readFile(ci)
    let stripped = text.replace(
      """  web:
    name: "Web: build"
    runs-on: ubuntu-24.04
    timeout-minutes: 15
""",
      """  web:
    name: "Web: build"
    runs-on: ubuntu-24.04
""")
    check stripped != text
    writeFile(ci, stripped)
    let result = fixture.runTask(@["ci-guards"])
    check result.exitCode == 1
    check result.stderr.contains(".github/workflows/ci.yml:web has no 'timeout-minutes: 15'")

  test "ci.yml keeps concurrency, the Nim cache and the coverage gate":
    let text = readFile(repoDir / ".github" / "workflows" / "ci.yml")
    check text.contains("cancel-in-progress: ${{ github.event_name == 'pull_request' }}")
    check text.contains("nimcache-${{ runner.os }}-")
    check text.contains("coverage-gate:")
    check text.contains(
      "needs: [api-check, api-test, contract, supply-chain, web, e2e, mutation, image, coverage-gate]")

