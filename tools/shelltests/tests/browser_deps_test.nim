# OPS-22: `./task browser-deps` replaced `playwright install --with-deps`,
# which let apt resolve every Recommends: and spent a 15-minute job's budget in
# a slow mirror three times. The behaviour that matters is which packages apt is
# asked for, that a warm runner touches apt at all, and that a slow mirror stops
# at the budget instead of the job cap.

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
    # The gate is `uname`, and the runner that executes this suite is Linux.
    fixture.installFake("uname", "#!/bin/sh\nprintf 'Darwin\\n'\n")
    let result = fixture.runTask(@["browser-deps"])
    check result.exitCode == 0
    check result.stdout.contains("not Linux, nothing to install")

  test "a warm runner does not touch apt":
    let fixture = newFixture("browser-deps-warm")
    defer: removeDir(fixture.root)
    copyList(fixture)
    installLinuxFakes(fixture)
    fixture.installFake("dpkg", "#!/bin/sh\nexit 0\n")
    let result = fixture.runTask(@["browser-deps"])
    check result.exitCode == 0
    check result.stdout.contains("all 72 packages already installed")
    check not fileExists(fixture.root / "home" / "apt.log")

  test "only the missing packages are asked for, without recommends":
    let fixture = newFixture("browser-deps-cold")
    defer: removeDir(fixture.root)
    copyList(fixture)
    installLinuxFakes(fixture)
    let result = fixture.runTask(@["browser-deps"])
    check result.exitCode == 0
    check result.stdout.contains("installing 71 missing package(s)")
    let log = readFile(fixture.root / "home" / "apt.log")
    check log.contains("--no-install-recommends")
    check log.contains("Acquire::http::Timeout=15")
    check log.contains("libevent-2.1-7t64")
    # The one package the fake dpkg already reports stays out of the request.
    check not log.contains("install libcairo2 ")

  test "an apt that fails names the budget instead of the job cap":
    let fixture = newFixture("browser-deps-slow")
    defer: removeDir(fixture.root)
    copyList(fixture)
    installLinuxFakes(fixture)
    fixture.installFake("apt-get", "#!/bin/sh\nexit 100\n")
    let result = fixture.runTask(@["browser-deps"], extraEnv = @[
      ("MAJADU_BROWSER_DEPS_TIMEOUT", "300")])
    check result.exitCode == 1
    check result.stderr.contains("did not finish in 300s")

  test "a package apt claimed but did not install fails the target":
    let fixture = newFixture("browser-deps-silent")
    defer: removeDir(fixture.root)
    copyList(fixture)
    installLinuxFakes(fixture)
    fixture.installFake("apt-get", "#!/bin/sh\nexit 0\n")
    let result = fixture.runTask(@["browser-deps"])
    check result.exitCode == 1
    check result.stderr.contains("still absent")
