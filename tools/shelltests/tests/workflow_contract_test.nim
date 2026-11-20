# OPS-19: the CI contract that is not enforced by running the pipeline.
#
# The workflows are read as files, because a checkout on macOS cannot run
# GitHub Actions. The cases cover the two properties a future edit silently
# drops: every job keeps the 15-minute cap, and ci.yml keeps its concurrency
# group, its compiler cache and no cross-workflow poll in the gate.

import std/[os, sequtils, strutils, unittest]
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
    # up to 12 minutes; the instrumented graph is gone since 2026-11-20.
    check not text.contains("actions/workflows/coverage.yml/runs")
    check not text.contains("  coverage-gate:")
    # `image` waits for the gate, so the gate's needs stay the in-repo quality
    # jobs. W26 (§12.1) put `preflight` in front of them; the fan-in keeps its
    # name, because `Gate` is the required status check.
    check text.contains(
      "needs: [preflight, api-check, api-test, supply-chain, web, e2e, mutation]")

  # W26 (QOUVER_CICD_STANDARD §12.1): the cheap gate has to exist and sit in
  # front of every expensive job. Measured on main 75a029cb: `preflight` costs
  # ~81 s, the run wall is 653 s, and three of the five red main runs since
  # 5 Nov failed in the checks it owns. A cheap job that nothing waits for is
  # the old shape with a new name.
  test "every expensive job waits for preflight":
    let text = readFile(repoDir / ".github" / "workflows" / "ci.yml")
    check text.contains("  preflight:")
    for job in ["api-check", "api-test", "supply-chain", "web",
                "e2e", "mutation"]:
      let body = text.split("  " & job & ":")[1]
      check body.split("\n\n")[0].contains("needs: [preflight]")
    # `gate` is a fan-in and must stay one: moving the required check onto the
    # cheap job would let main merge on a gate that only read the contract.
    check text.contains("  gate:\n    name: \"Gate\"")

  # OPS-20 / 2026-11-20: the instrumented graph left the pipeline, so the tools
  # are only used by `./task coverage` and the per-file floor is the debt check
  # that `./task check` runs on every push. A workflow file reappearing here
  # would be a second graph for the same push, which is what was removed.
  test "no coverage workflow, and the per-file floor stays in ./task check":
    check not fileExists(repoDir / ".github" / "workflows" / "coverage.yml")
    let tools = readFile(repoDir / "task.d" / "coverage-tools.sh")
    check tools.contains("want_lcov=2.6")
    check tools.contains("want_gcovr=8.8")
    let checkScript = readFile(repoDir / "task.d" / "check.sh")
    check checkScript.contains("coverage-debt.sh")

  # B-02 / W28 (QOUVER_CICD_STANDARD §12.2): the runtime packages and the pinned
  # coverage tools are provisioned once per cache key. An inline apt block pays
  # the mirror in every job that needs one shared library, which measured 30 to
  # 44s per job across ten main runs and 186s in the worst one. nightly.yml is
  # exempt on purpose: it is scheduled for deletion (§11.7).
  #
  # 2026-11-20: no CI job installs the coverage tools any more. The graph that
  # read their reports is gone, `./task coverage` is a local target, and the step
  # that installed lcov and gcovr per shard was pure setup cost. A workflow that
  # starts calling `./task coverage-tools` again is a second graph reappearing
  # through the back door.
  test "no workflow installs the runtime packages or the coverage tools inline":
    # Only executable lines count: the comments name the old call to explain why
    # it left, and a guard that reads prose fails on its own documentation.
    for workflow in ["ci.yml", "release.yml"]:
      var text = ""
      for line in readFile(repoDir / ".github" / "workflows" / workflow).splitLines():
        if line.strip().startsWith("#"):
          continue
        text.add(line & "\n")
      check text.contains("./task runtime-deps")
      check not text.contains("apt-get install -y \"${apt_opts[@]}\" libpcre3")
      check not text.contains("git clone --depth 1 --branch v2.6")
      check not text.contains("./task coverage-tools")
      check not text.contains("lcov --version")
      check not text.contains("gcovr --version")

  # W8 (QOUVER_CICD_STANDARD §11.2): the shard count is a single decision, and
  # the matrix, the job name and the `--shard I/N` argument are three places that
  # can drift apart. A matrix of three with `--shard "$SHARD/2"` runs two thirds
  # of the suites twice and skips the rest, which no exit code reports.
  test "every sharded job runs the shard count its matrix declares":
    var seen = 0
    for workflow in ["ci.yml", "release.yml"]:
      let lines = readFile(repoDir / ".github" / "workflows" / workflow).splitLines()
      var declared = ""
      for line in lines:
        let stripped = line.strip()
        if stripped.startsWith("shard: [") and declared == "":
          declared = stripped
      check declared != ""
      inc seen
      let n = declared.count('"') div 2
      check n >= 2
      check lines.anyIt(it.contains("--shard \"$SHARD/" & $n & "\""))
      # The two name styles in use: `(shard 1/3)` in ci.yml and `shard 1 of 3`
      # in release.yml. Either one has to carry the matrix count.
      check lines.anyIt(it.contains("shard ${{ matrix.shard }}/" & $n) or
        it.contains("shard ${{ matrix.shard }} of " & $n))
      # `./task test-costs` projects the split it writes, so its default has to
      # be the count the workflows run or the printed projection is fiction.
      let costs = readFile(repoDir / "task.d" / "test-costs.sh")
      check costs.contains("shards=" & $n)
    check seen == 2

  # OPS-22: an e2e job that installs browser dependencies through apt has spent
  # the whole 15-minute budget there three times (14m24s on 2026-11-10, 13m47s
  # and 13m36s on 2026-11-18), and `--with-deps` resolving Recommends: is what
  # made it 181 packages instead of the 62 the browsers link against. The
  # contract is the pinned list: binaries first, then `./task browser-deps`, then
  # `./task browser-check` so a missing library is named in its own step.
  test "no workflow and no CI path installs browsers with a bare --with-deps":
    for kind, path in walkDir(repoDir / ".github" / "workflows"):
      if kind != pcFile:
        continue
      var text = ""
      for line in readFile(path).splitLines():
        # The comments name the old call to explain why it left, so only the
        # executable lines count.
        if line.strip().startsWith("#"):
          continue
        text.add(line & "\n")
      check not text.contains("playwright install --with-deps")
      if text.contains("playwright install\n"):
        check text.contains("./task browser-deps")
        check text.contains("./task browser-check")

  test "browser-deps caps the apt run and keeps the set --with-deps resolves":
    let text = readFile(repoDir / "task.d" / "browser-deps.sh")
    check text.contains("e2e/system-deps.txt")
    # The whole apt run is capped, so a stalled mirror cannot spend the job.
    check text.contains("MAJADU_BROWSER_DEPS_TIMEOUT")
    check text.contains("timeout \"$budget\"")
    # Recommends must stay on: the closure carries 117 fonts, and without them
    # the scoreboard's box glyphs render as tofu and every visual test fails.
    check not text.contains("--no-install-recommends")
    # A cache hit has to install without a mirror.
    check text.contains("--no-download")
    check text.contains("MAJADU_BROWSER_DEPS_CACHE")
    let list = readFile(repoDir / "e2e" / "system-deps.txt")
    # One entry per group Playwright installs for; a dropped group is a silent
    # visual-baseline change, so the guard names each.
    for needed in ["libevent-2.1-7t64", "libavcodec60", "libx11-xcb1",
                   "fonts-unifont", "xvfb"]:
      check list.contains(needed)

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
