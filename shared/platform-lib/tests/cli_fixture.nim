## The CLI contract every tool under `tools/` follows, exercised in a child
## process. `fail`, `usageFail` and `flags` read the current process' exit code
## and command line, so the only honest way to test them is to run a small
## program that uses them and read what the shell would see.
##
## Not named `*_test.nim`: it is a fixture, not a suite, and `./task test` must
## not try to run it.

import std/os
import ../cli

const program = "cli_fixture"

proc main() =
  case paramStr(1)
  of "fail":
    fail(program, "the database said no")
  of "usage":
    usageFail(program, "unknown flag --nope")
  of "flags":
    ## Every flag from the first argument, with `--name` as the only one that
    ## takes a value.
    for (flag, value) in flags(program, 2, ["--name"]):
      stdout.writeLine(flag & "=" & value)
  else:
    usageFail(program, "unknown command: " & paramStr(1))

main()