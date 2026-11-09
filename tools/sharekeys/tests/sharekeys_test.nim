## The share key tool. `generate` and the rotate guards are the two operations an
## operator runs during a key rotation, and nothing exercised either: the binary
## has no other caller. It reads `paramStr`, so the cases re-execute this test
## binary with a probe variable set and let the imported `main` parse the line.

import std/[base64, json, os, osproc, strtabs, strutils, unittest]

import ../main

const probeVariable = "SHAREKEYS_TEST_PROBE"

proc probeEnv(extra: seq[(string, string)]): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for (key, item) in envPairs():
    result[key] = item
  result[probeVariable] = "1"
  # Every case starts from a known keyring: a value left in the developer's
  # shell must not decide whether a case passes.
  for name in ["MAJADU_PG_DSN", "SHARE_CODE_KEYS", "SHARE_CODE_ACTIVE_KEY_ID"]:
    result.del(name)
  for (key, item) in extra:
    result[key] = item

proc diagnostics(output: string): string =
  ## The lines the program itself wrote. `execCmdEx` merges stderr into its
  ## output, and an instrumented build (`./task coverage`) has the profiling
  ## runtime writing warnings there.
  for line in output.splitLines():
    if line.startsWith("profiling:"):
      continue
    if result.len > 0:
      result.add "\n"
    result.add line

proc runTool(args: seq[string];
    extra: seq[(string, string)] = @[]): tuple[output: string, status: int] =
  var binary = getAppFilename()
  if not binary.isAbsolute:
    binary = getCurrentDir() / binary
  var command = quoteShell(binary)
  for argument in args:
    command.add " " & quoteShell(argument)
  let outcome = execCmdEx(command, env = probeEnv(extra))
  (output: outcome.output, status: outcome.exitCode)

when isMainModule:
  # The probe path must stop after `main`: without the quit, the child would go
  # on to run the suites and its output would be read as part of the command's.
  if getEnv(probeVariable) == "1":
    main()
    quit(0)

const
  keys = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","2":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="}"""
  # A DSN that cannot be reached: a case that prints and exits without
  # connecting proves it never opened a connection, because the connection would
  # fail first.
  unreachableDsn = "postgresql://nobody@127.0.0.1:1/bm2_none"

suite "generate":
  test "prints a 32 byte key and the line that activates it":
    let run = runTool(@["generate", "--id", "7"])
    check run.status == 0
    let lines = diagnostics(run.output).strip().splitLines()
    check lines.len == 2
    let document = parseJson(lines[0])
    let encoded = document["7"].getStr()
    check encoded.len == 44
    check encoded.endsWith("=")
    check decode(encoded).len == 32
    check lines[1].contains("SHARE_CODE_ACTIVE_KEY_ID=7")

  test "defaults to key id 1 and never repeats itself":
    let first = runTool(@["generate"])
    let second = runTool(@["generate"])
    check first.status == 0
    check first.output.contains("SHARE_CODE_ACTIVE_KEY_ID=1")
    check first.output != second.output

suite "rotate":
  test "without --from or --to it is a usage failure":
    let missing = runTool(@["rotate"])
    check missing.status == 2
    check missing.output.contains("rotate needs --from and --to")
    check runTool(@["rotate", "--from", "1"]).status == 2
    check runTool(@["rotate", "--to", "2"]).status == 2

  test "a dry run prints and exits without opening the database":
    let run = runTool(@["rotate", "--from", "1", "--to", "2", "--dry-run"],
      @[("MAJADU_PG_DSN", unreachableDsn), ("SHARE_CODE_KEYS", keys),
        ("SHARE_CODE_ACTIVE_KEY_ID", "2")])
    check run.status == 0
    check run.output.contains("dry run, nothing written")

  test "a dry run still needs a keyring":
    let run = runTool(@["rotate", "--from", "1", "--to", "2", "--dry-run"],
      @[("MAJADU_PG_DSN", unreachableDsn),
        ("SHARE_CODE_ACTIVE_KEY_ID", "2")])
    check run.status != 0
    check run.output.contains("SHARE_CODE_KEYS is required")

  test "an unknown flag is a usage failure":
    let run = runTool(@["generate", "--nope"])
    check run.status == 2
    check run.output.contains("unknown argument: --nope")

suite "retire-legacy":
  test "without --older-than it is a usage failure":
    let run = runTool(@["retire-legacy"])
    check run.status == 2
    check run.output.contains("retire-legacy needs --older-than")

  test "a window that is not a whole number is a usage failure":
    let notANumber = runTool(@["retire-legacy", "--older-than", "thirty"])
    check notANumber.status == 2
    check notANumber.output.contains("--older-than must be a whole number of days")
    let zero = runTool(@["retire-legacy", "--older-than", "0"])
    check zero.status == 2
    check zero.output.contains("--older-than must be at least 1")

  test "a missing DSN is a runtime failure, not a usage one":
    let run = runTool(@["retire-legacy", "--older-than", "30"])
    check run.status == 1
    check run.output.contains("MAJADU_PG_DSN is required")

suite "usage":
  test "no subcommand and an unknown subcommand both print the usage block":
    let none = runTool(@[])
    check none.status == 2
    check none.output.contains("Usage: sharekeys")

    let unknown = runTool(@["rotatee"])
    check unknown.status == 2
    check unknown.output.contains("Usage: sharekeys")