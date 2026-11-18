# OPS-22: `./task browser-deps` replaced `playwright install --with-deps`,
# which let apt resolve a 181-package, 125 MB set on a slow mirror and spent a
# 15-minute job's budget there three times. The behaviour that matters is which
# packages apt is asked for, that Recommends stay on (the font set the visual
# baselines were recorded with), that a cache hit never reaches a mirror, and
# that a slow mirror stops at the budget instead of the job cap.

import std/[os, strutils, unittest]
import ../harness

const fakeDpkg = """#!/bin/sh
# `dpkg -s <package>`; the installed set is whatever the fake apt-get wrote.
[ -f "$HOME/apt-ran" ] && exit 0
case "$2" in
  libcairo2) exit 0 ;;
  *) exit 1 ;;
esac
"""

const fakeApt = """#!/bin/sh
printf '%s\n' "$*" >>"$HOME/apt.log"
case "$*" in
  *install*) : >"$HOME/apt-ran" ;;
esac
exit 0
"""

const fakeSudo = """#!/bin/sh
exec "$@"
"""

const fakeTimeout = """#!/bin/sh
# The budget itself is asserted through the message; here it just runs the job.
shift
exec "$@"
"""

proc installLinuxFakes(fixture: Fixture) =
  ## The runner is Linux; this host is not. `uname` decides, so it is the fake.
  fixture.installFake("uname", "#!/bin/sh\nprintf 'Linux\\n'\n")
  fixture.installFake("dpkg", fakeDpkg)
  fixture.installFake("apt-get", fakeApt)
  fixture.installFake("sudo", fakeSudo)
  fixture.installFake("timeout", fakeTimeout)

proc copyList(fixture: Fixture) =
  createDir(fixture.root / "e2e")
  copyFile(repoDir / "e2e" / "system-deps.txt",
    fixture.root / "e2e" / "system-deps.txt")

suite "browser deps":
  test "a developer host installs nothing":
    let fixture = newFixture("browser-deps-macos")
    defer: removeDir(fixture.root)
    copyList(fixture)
    let result = fixture.runTask(@["browser-deps"])
    check result.exitCode == 0
    check result.stdout.contains("not Linux, nothing to install")

  test "a runner with every package present does not touch apt":
    let fixture = newFixture("browser-deps-warm")
    defer: removeDir(fixture.root)
    copyList(fixture)
    installLinuxFakes(fixture)
    fixture.installFake("dpkg", "#!/bin/sh\nexit 0\n")
    let result = fixture.runTask(@["browser-deps"])
    check result.exitCode == 0
    check result.stdout.contains("already installed")
    check not fileExists(fixture.root / "home" / "apt.log")

  test "only the missing packages are asked for, and Recommends stay on":
    let fixture = newFixture("browser-deps-cold")
    defer: removeDir(fixture.root)
    copyList(fixture)
    installLinuxFakes(fixture)
    let result = fixture.runTask(@["browser-deps"])
    check result.exitCode == 0
    let log = readFile(fixture.root / "home" / "apt.log")
    check log.contains("libevent-2.1-7t64")
    # The set must stay the one `--with-deps` resolves: no Recommends flag, and
    # no narrowed package list, or the font fallback changes and the committed
    # visual baselines fail.
    check not log.contains("--no-install-recommends")
    check log.contains("Acquire::http::Timeout=15")

  test "the list carries every group Playwright installs for":
    ## Dropping a group is a silent visual-baseline change, not a smaller
    ## install, so the file has to name firefox's libraries as well.
    let list = readFile(repoDir / "e2e" / "system-deps.txt")
    for needed in ["libevent-2.1-7t64", "libavcodec60", "libx11-xcb1",
                   "fonts-unifont", "xvfb"]:
      check list.contains(needed)

  test "an apt that hits the budget names the budget, not the job cap":
    let fixture = newFixture("browser-deps-slow")
    defer: removeDir(fixture.root)
    copyList(fixture)
    installLinuxFakes(fixture)
    fixture.installFake("apt-get", "#!/bin/sh\nexit 100\n")
    fixture.installFake("timeout", "#!/bin/sh\nexit 124\n")
    let result = fixture.runTask(@["browser-deps"], extraEnv = @[
      ("MAJADU_BROWSER_DEPS_TIMEOUT", "300")])
    check result.exitCode == 1
    check result.stderr.contains("did not finish in 300s")

  test "an apt failure that is not the budget reports apt's own exit code":
    ## A DNS failure is not a slow mirror: blaming the budget would send the
    ## reader after the wrong fix.
    let fixture = newFixture("browser-deps-aptfail")
    defer: removeDir(fixture.root)
    copyList(fixture)
    installLinuxFakes(fixture)
    fixture.installFake("apt-get", "#!/bin/sh\nexit 100\n")
    let result = fixture.runTask(@["browser-deps"], extraEnv = @[
      ("MAJADU_BROWSER_DEPS_TIMEOUT", "300")])
    check result.exitCode == 1
    check result.stderr.contains("failed with exit 100")
    check not result.stderr.contains("did not finish")

  test "a cache hit installs without downloading":
    let fixture = newFixture("browser-deps-cache")
    defer: removeDir(fixture.root)
    copyList(fixture)
    installLinuxFakes(fixture)
    let cacheDir = fixture.root / "debs"
    createDir(cacheDir)
    writeFile(cacheDir / "libevent-2.1-7t64_2.1.12_amd64.deb", "placeholder")
    let result = fixture.runTask(@["browser-deps"], extraEnv = @[
      ("MAJADU_BROWSER_DEPS_CACHE", cacheDir)])
    check result.exitCode == 0
    check result.stdout.contains("cached .deb set")
    check result.stdout.contains("from cache")
    let log = readFile(fixture.root / "home" / "apt.log")
    check log.contains("--no-download")
    check not log.contains("apt-get update")

  test "a package apt claimed but did not install fails the target":
    let fixture = newFixture("browser-deps-silent")
    defer: removeDir(fixture.root)
    copyList(fixture)
    installLinuxFakes(fixture)
    fixture.installFake("apt-get", "#!/bin/sh\nexit 0\n")
    let result = fixture.runTask(@["browser-deps"])
    check result.exitCode == 1
    check result.stderr.contains("still absent")
