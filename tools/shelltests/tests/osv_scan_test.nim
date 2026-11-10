# SEC-05: the target has to turn a scanner report into a verdict. The scanner is
# a pinned release binary that is not installed on a developer machine, so the
# fixture supplies a fake `osv-scanner` that writes a report and exits like the
# real one (1 when it found anything). The verdict itself is the real gate: the
# fixture's fake compiler installs the binary this suite builds from
# `tools/osvgate/main.nim`, so the severity decision under test is the shipped one.

import std/[os, osproc, strutils, unittest]
import ../harness

const report = """{
  "results": [{
    "source": {"path": "pnpm-lock.yaml", "type": "lockfile"},
    "packages": [{
      "package": {"name": "glob", "version": "11.1.0", "ecosystem": "npm"},
      "vulnerabilities": [{
        "id": "GHSA-3g3m-2fjr-6pw4",
        "database_specific": {"severity": "__SEVERITY__"}
      }]
    }]
  }]
}
"""

const fakeNim = """#!/bin/sh
out=
copy=0
for arg in "$@"; do
  case "$arg" in
    -o:*) out=${arg#-o:} ;;
    *tools/osvgate/main.nim) copy=1 ;;
  esac
done
[ -n "$out" ] || exit 0
mkdir -p "$(dirname "$out")"
if [ "$copy" = 1 ]; then
  cp "$REAL_OSVGATE" "$out"
else
  printf '#!/bin/sh\nexit 0\n' >"$out"
fi
chmod +x "$out"
exit 0
"""

proc buildGate(): string =
  ## The real `tools/osvgate` binary, built once for the whole suite.
  result = getTempDir() / "majadu-osvgate-test-bin"
  if fileExists(result):
    return
  let command = "nim c --hints:off -o:" & quoteShell(result) & " " &
    quoteShell(repoDir / "tools" / "osvgate" / "main.nim")
  let (output, code) = execCmdEx(command, workingDir = repoDir)
  if code != 0:
    echo output
    raise newException(OSError, "cannot build tools/osvgate")

proc fakeScanner(severity: string): string =
  ## `--output-file=<path>` is the only flag this step depends on.
  let body = report.replace("__SEVERITY__", severity)
  let quoted = body.replace("'", "'\\''")
  "#!/bin/sh\n" &
    "out=\n" &
    "for arg in \"$@\"; do\n" &
    "  case \"$arg\" in\n" &
    "    --output-file=*) out=${arg#--output-file=} ;;\n" &
    "  esac\n" &
    "done\n" &
    "[ -n \"$out\" ] || exit 2\n" &
    "printf '%s' '" & quoted & "' >\"$out\"\n" &
    "exit 1\n"

suite "osv-scan":
  test "a report with no high finding passes":
    let fixture = newFixture("osv-scan-moderate")
    defer: removeDir(fixture.root)
    discard fixture.installFake("nim", fakeNim)
    discard fixture.installFake("osv-scanner", fakeScanner("MODERATE"))
    let result = fixture.runTask(@["osv-scan"],
      extraEnv = @[("REAL_OSVGATE", buildGate())])
    check result.exitCode == 0
    check result.stdout.contains("osvgate: ok (1 finding(s), none at high or critical)")

  test "a high finding fails and names the advisory and the package":
    let fixture = newFixture("osv-scan-high")
    defer: removeDir(fixture.root)
    discard fixture.installFake("nim", fakeNim)
    discard fixture.installFake("osv-scanner", fakeScanner("HIGH"))
    let result = fixture.runTask(@["osv-scan"],
      extraEnv = @[("REAL_OSVGATE", buildGate())])
    check result.exitCode == 1
    check result.stderr.contains("GHSA-3g3m-2fjr-6pw4")
    check result.stderr.contains("glob")
    check result.stderr.contains("pnpm-lock.yaml")

  test "a scanner that never wrote a report fails instead of reading as clean":
    let fixture = newFixture("osv-scan-broken")
    defer: removeDir(fixture.root)
    discard fixture.installFake("nim", fakeNim)
    fixture.installFake("osv-scanner", "#!/bin/sh\nexit 3\n")
    let result = fixture.runTask(@["osv-scan"],
      extraEnv = @[("REAL_OSVGATE", buildGate())])
    check result.exitCode == 1
    check result.stderr.contains("osv-scanner exited 3 without a report")
