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

  test "ci.yml keeps concurrency, the Nim cache and no cross-workflow poll":
    let text = readFile(repoDir / ".github" / "workflows" / "ci.yml")
    check text.contains("cancel-in-progress: ${{ github.event_name == 'pull_request' }}")
    check text.contains("nimcache-${{ runner.os }}-")
    # W9 (QOUVER_CICD_STANDARD §11.2): a Class A workflow may not wait on another
    # workflow's run. The check that used to poll coverage.yml held the CI wall for
    # up to 12 minutes; `Coverage: ratchet` reports on its own instead.
    check not text.contains("actions/workflows/coverage.yml/runs")
    check not text.contains("  coverage-gate:")
    # `image` waits for the gate, so the gate's needs stay the in-repo quality jobs.
    check text.contains(
      "needs: [api-check, api-test, contract, supply-chain, web, e2e, mutation]")

  # OPS-20: the coverage gate used the distro tools and could be cancelled by
  # the next push.
  test "coverage.yml measures with the locked tools and cannot be cancelled on main":
    let text = readFile(repoDir / ".github" / "workflows" / "coverage.yml")
    check text.contains("gcovr==8.8")
    check text.contains("--branch v2.6")
    check text.contains("./task deps-check")
    check text.contains("cancel-in-progress: ${{ github.event_name == 'pull_request' }}")
    check not text.contains("apt-get install -y lcov gcovr")
    # A rewritten PR history has no merge base, and the workflow refuses it
    # instead of inheriting the skip in task.d/coverage.sh.
    check text.contains("git merge-base HEAD \"origin/$BASE_REF\"")

  # OPS-22: release.yml's e2e job ran a bare `--with-deps` and spent the whole
  # 15-minute budget in apt (release run 44267937137 on tag v2.0.5, cancelled at
  # 13m36s), so no image and no GitHub Release followed. The launch-check shape
  # ci.yml already uses is the contract: install the binaries, start each engine
  # once, and pay for apt only when a launch fails.
  test "release.yml installs browsers with the launch check and no bare --with-deps":
    let text = readFile(repoDir / ".github" / "workflows" / "release.yml")
    check text.contains("      - name: \"E2E: install browsers\"")
    check text.contains("pnpm exec playwright install\n")
    check text.contains("a cached browser could not start; installing the system dependencies")
    check text.contains("99-majadu-timeout")
    check not text.contains("run: pnpm exec playwright install --with-deps")

  # ISO-14: the Linux baseline is committed, so CI may only compare it.
  test "no CI path records a visual baseline":
    for workflow in ["ci.yml", "release.yml"]:
      let text = readFile(repoDir / ".github" / "workflows" / workflow)
      check not text.contains("--update-snapshots")
      check not text.contains("update_snapshots")
    let text = readFile(repoDir / ".github" / "workflows" / "ci.yml")
    check text.contains("E2E: require the Linux baseline")
    check dirExists(repoDir / "e2e" / "__screenshots__" / "linux")
    check fileExists(repoDir / "e2e" / "__screenshots__" / "linux" /
      "home-iphone-17.png")
