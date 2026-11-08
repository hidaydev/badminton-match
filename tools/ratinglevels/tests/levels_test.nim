## TL-13: what `ratinglevels` accepts and what its dry run promises.
##
## `fail` and `usageFail` end the process, so every refusal is asserted by
## running the compiled tool and reading its exit code and message. The two
## halves that return normally are called in-process through the exports D-5
## allows, so the accepted side is stated once instead of being inferred from a
## green CLI run.
##
## The row the suite writes lives in a scratch community of its own, never in a
## seeded one, and is deleted in teardown.
import std/[json, options, os, osproc, strtabs, strutils, unittest]
import db/db
import ../main

const slug = "levels-test"

proc repoRoot(): string =
  ## The tool is built from the repository root so `config.nims` supplies the
  ## module paths.
  var dir = currentSourcePath().parentDir
  for _ in 0 ..< 8:
    if fileExists(dir / "tools/ratinglevels/main.nim"):
      return dir
    let parent = parentDir(dir)
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot find the repository root from " & currentSourcePath())

proc toolBinary(): string =
  ## `./task check` compiles suites, not the tools, so the CLI is exercised
  ## through a binary built once here. `RATINGLEVELS_BIN` lets a run reuse one.
  var built {.global.}: string
  if built.len > 0:
    return built
  let fromEnv = getEnv("RATINGLEVELS_BIN")
  if fromEnv.len > 0 and fileExists(fromEnv):
    return fromEnv
  let root = repoRoot()
  let directory = getTempDir() / ("majadu-ratinglevels-" & $getCurrentProcessId())
  createDir(directory)
  built = directory / "ratinglevels"
  let (output, code) = execCmdEx("nim c --hints:off --nimcache:" &
    quoteShell(directory / "nimcache") & " -o:" & quoteShell(built) & " " &
    quoteShell(root / "tools/ratinglevels/main.nim"), workingDir = root)
  if code != 0 or not fileExists(built):
    raise newException(IOError, "cannot build ratinglevels:\n" & output)
  built

proc runCli(arguments: string): tuple[output: string, exitCode: int] =
  execCmdEx(quoteShell(toolBinary()) & " " & arguments, workingDir = repoRoot())

proc runWithoutDsn(arguments: string): tuple[output: string, exitCode: int] =
  ## The environment minus the connection string: an argument complaint must
  ## not depend on a database being reachable.
  var environment = newStringTable(modeCaseSensitive)
  for (key, value) in envPairs():
    if key != "MAJADU_PG_DSN":
      environment[key] = value
  execCmdEx(quoteShell(toolBinary()) & " " & arguments,
    workingDir = repoRoot(), env = environment)

var
  database: Db
  communityId: string

proc cleanup() =
  # `rating.levels` and `community.settings` cascade from the community, and a
  # fresh community owns no players, so one delete removes every row this suite
  # could have written.
  discard database.execUpdate(
    "delete from platform.community where slug = $1", @[textParam(slug)])

proc storedLevel(kind: string): Option[Row] =
  database.queryOne(
    """select champion_points::text as champion, round_ratios::text as ratios,
              enabled
       from rating.levels where community_id = $1::uuid and kind = $2""",
    @[textParam(communityId), textParam(kind)])

suite "ratinglevels":
  setup:
    let dsn = getEnv("MAJADU_PG_DSN")
    if dsn.len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    database = openDb(dsn, 1)
    cleanup()
    communityId = database.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ($1, 'Levels Test', 'Asia/Jakarta') returning id""",
      @[textParam(slug)]).get.get("id")

  teardown:
    cleanup()
    database.close()

  test "a ratio above 1 and one below 0 are refused":
    for raw in ["""{"final": 1.01}""", """{"final": -0.01}"""]:
      let run = runCli("set --community " & slug &
        " --kind session --champion 2500 --ratios " & quoteShell(raw))
      check run.exitCode == 1
      check run.output.contains("ratio final must be within [0,1]")
    check storedLevel("session").isNone

  test "non-JSON is refused as invalid JSON":
    let run = runCli("set --community " & slug &
      " --kind session --champion 2500 --ratios " & quoteShell("{not json"))
    check run.exitCode == 1
    check run.output.contains("ratios must be valid JSON")

  test "a JSON array, string and null all reach the object refusal":
    for raw in ["[1]", "\"x\"", "null"]:
      let run = runCli("set --community " & slug &
        " --kind session --champion 2500 --ratios " & quoteShell(raw))
      check run.exitCode == 1
      check run.output.contains("ratios must be a JSON object")

  test "an integer 0 and 1 are accepted as ratios":
    let parsed = validateRatios("""{"group": 0, "final": 1}""")
    check parsed.kind == JObject
    check parsed["group"].getInt() == 0
    check parsed["final"].getInt() == 1

  test "requireKind takes the three ladder kinds and refuses the rest":
    # `fail` ends the process, so reaching the next line is the acceptance
    # evidence; the list is compared so the case states the three kinds.
    var accepted: seq[string] = @[]
    for kind in ["session", "tournament_classic", "tournament_team"]:
      requireKind(kind)
      accepted.add(kind)
    check accepted == @["session", "tournament_classic", "tournament_team"]
    let run = runCli("set --community " & slug &
      " --kind pool --champion 2500")
    check run.exitCode == 1
    check run.output.contains("unknown kind: pool")

  test "set --dry-run prints create and writes nothing":
    let run = runCli("set --community " & slug &
      " --kind session --champion 2500 --ratios " &
      quoteShell("""{"final": 0.9}""") & " --dry-run")
    check run.exitCode == 0
    let plan = parseJson(run.output)
    check plan["dryRun"].getBool
    check plan["action"].getStr == "create"
    check plan["kind"].getStr == "session"
    check plan["championPoints"].getFloat == 2500.0
    check plan["roundRatios"]["final"].getFloat == 0.9
    check storedLevel("session").isNone

  test "set --dry-run on an existing row prints update":
    discard runCli("set --community " & slug &
      " --kind session --champion 2500")
    let run = runCli("set --community " & slug &
      " --kind session --champion 3000 --dry-run")
    check run.exitCode == 0
    check parseJson(run.output)["action"].getStr == "update"
    check storedLevel("session").get.get("champion") == "2500.00"

  test "clear --dry-run prints noop without a row and delete with one":
    let absent = runCli("clear --community " & slug & " --kind session --dry-run")
    check absent.exitCode == 0
    check parseJson(absent.output)["action"].getStr == "noop"
    discard runCli("set --community " & slug & " --kind session --champion 2500")
    let present = runCli("clear --community " & slug & " --kind session --dry-run")
    check present.exitCode == 0
    check parseJson(present.output)["action"].getStr == "delete"
    check storedLevel("session").isSome

  test "set without --ratios keeps the stored ratios, with it replaces them":
    discard runCli("set --community " & slug & " --kind session" &
      " --champion 2500 --ratios " & quoteShell("""{"final": 0.9, "sf": 0.7}"""))
    discard runCli("set --community " & slug & " --kind session --champion 3000")
    let kept = storedLevel("session").get
    check parseFloat(kept.get("champion")) == 3000.0
    check parseJson(kept.get("ratios"))["final"].getFloat == 0.9
    check parseJson(kept.get("ratios"))["sf"].getFloat == 0.7
    discard runCli("set --community " & slug & " --kind session" &
      " --champion 3000 --ratios " & quoteShell("""{"final": 0.5}"""))
    let replaced = storedLevel("session").get
    check parseJson(replaced.get("ratios")).len == 1
    check parseJson(replaced.get("ratios"))["final"].getFloat == 0.5

  test "an incomplete line exits 2 without a database":
    let incomplete = runWithoutDsn("set --community " & slug)
    check incomplete.exitCode == 2
    check incomplete.output.contains("set needs --community, --kind and --champion")
    let noKind = runWithoutDsn("clear --community " & slug)
    check noKind.exitCode == 2
    check noKind.output.contains("clear needs --community and --kind")