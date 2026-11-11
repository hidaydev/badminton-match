# SQ-11: `void promise.then(...)` has to fail the lint, not only be described in
# `eslint.config.js`. The proof lives in `apps/web/scripts/check-lint-rule.mjs`
# so the web gate runs it on every push; this suite runs the same script from the
# repository, which is where a local `./task check` looks for it.
#
# The script needs the installed workspace, so the suite skips (77) on a runner
# that has not run `pnpm install` — the `web` job is the one that has it.

import std/[os, osproc, strutils, unittest]
import ../harness

let webDir = repoDir / "apps" / "web"

if not dirExists(webDir / "node_modules"):
  echo "SKIP web lint rule: apps/web/node_modules is missing (run pnpm install)"
  quit(77)

suite "web lint rule":
  test "void on a promise fails and the awaited form passes":
    let outcome = execCmdEx("node scripts/check-lint-rule.mjs",
      options = {poStdErrToStdOut, poUsePath}, workingDir = webDir)
    checkpoint(outcome.output)
    check outcome.exitCode == 0
    check outcome.output.contains("lint-rule: ok")
