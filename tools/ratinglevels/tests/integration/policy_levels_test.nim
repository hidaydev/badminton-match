## `./task levels` under the 0061 policy set.
##
## `tools/ratinglevels/main.nim` issued every `rating.levels` statement on the
## plain pool. Under the policy set a statement with no tenant declared sees no
## row, so `list` printed `{"items":[]}` with exit 0 while the owner saw a ladder,
## and `set` failed with "new row violates row-level security policy". A silent
## empty list is worse than the loud failure: an operator reads it as "this
## community has no ladder".
##
## The CLI is driven as `bm2_app`, through the same `options=-c role=bm2_app`
## route the API suites use, and the suite first proves the policy set actually
## binds on that connection: a probe with no tenant must see zero rows while the
## owner sees the seeded one. Without that guard a superuser connection would make
## every assertion below vacuous.
import std/[json, options, os, osproc, strutils, unittest]
import db/db
import tests/fixtures

const
  slug = "policy-levels-test"

proc repoRoot(): string =
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
  var built {.global.}: string
  if built.len > 0:
    return built
  let fromEnv = getEnv("RATINGLEVELS_BIN")
  if fromEnv.len > 0 and fileExists(fromEnv):
    built = fromEnv
    return built
  let root = repoRoot()
  let directory = getTempDir() / ("majadu-levels-policy-" & $getCurrentProcessId())
  createDir(directory)
  built = directory / "ratinglevels"
  let (output, code) = execCmdEx("nim c --hints:off --nimcache:" &
    quoteShell(directory / "nimcache") & " -o:" & quoteShell(built) & " " &
    quoteShell(root / "tools/ratinglevels/main.nim"), workingDir = root)
  if code != 0 or not fileExists(built):
    raise newException(IOError, "cannot build ratinglevels:\n" & output)
  built

proc appDsn(raw: string): string =
  ## The policy set constrains `bm2_app`, so the CLI has to reach the database as
  ## that role. `options` has to respect a query string the caller already set.
  let query = raw.find('?')
  let (head, tail) =
    if query >= 0: (raw[0 ..< query], raw[query + 1 .. ^1])
    else: (raw, "")
  const appRoleOption = "options=-c%20role%3Dbm2_app"
  if tail.len > 0: head & "?" & tail & "&" & appRoleOption
  else: head & "?" & appRoleOption

proc runCli(arguments: string, dsn: string): tuple[output: string, exitCode: int] =
  let previous = getEnv("MAJADU_PG_DSN")
  putEnv("MAJADU_PG_DSN", dsn)
  try:
    result = execCmdEx(quoteShell(toolBinary()) & " " & arguments,
      workingDir = repoRoot())
  finally:
    putEnv("MAJADU_PG_DSN", previous)

var
  database: Db
  appDatabase: Db
  communityId: string

proc cleanup() =
  purgeCommunity(database, slug)

proc seed() =
  cleanup()
  communityId = newCommunity(database, slug, "Policy Levels")

database = openDb(getEnv("MAJADU_PG_DSN"), 1)
let policiesOn = database.queryOne(
  """select count(*)::int as n from pg_policies
     where schemaname = 'rating' and tablename = 'levels'""").get.getInt("n") > 0
doAssert policiesOn, "policy_levels needs a database with the 0061 policy set; " &
  "run it in the job that applies 0061 (./task policy-test)"
seed()
let rawDsn = getEnv("MAJADU_PG_DSN")
# The CLI's own route, opened here as well so the probe below runs on exactly the
# connection the tool builds.
appDatabase = openDb(appDsn(rawDsn), 1)

suite "ratinglevels under the policy set":
  test "the policy set binds on the connection these cases use":
    # The guard. A superuser connection bypasses the policy and would make every
    # case below pass whether the fix is present or not.
    discard database.execUpdate(
      """insert into rating.levels (community_id, kind, champion_points,
                                    round_ratios, enabled)
         values ($1::uuid, 'session', 500, '{}'::jsonb, true)""",
      @[textParam(communityId)])
    check appDatabase.queryOne(
      "select count(*)::int as n from rating.levels").get.getInt("n") == 0
    check appDatabase.scoped(communityId).queryOne(
      "select count(*)::int as n from rating.levels").get.getInt("n") == 1

  test "list prints the ladder the owner can see":
    # Before the fix: {"items":[]} with exit 0.
    let (output, code) = runCli("list --community " & slug, appDsn(rawDsn))
    check code == 0
    let items = parseJson(output.strip())["items"]
    check items.len == 1
    check items[0]["community"].getStr() == slug
    check items[0]["kind"].getStr() == "session"
    check items[0]["championPoints"].getStr() == "500.00"

  test "list without --community sweeps every tenant":
    let (output, code) = runCli("list", appDsn(rawDsn))
    check code == 0
    var found = false
    for item in parseJson(output.strip())["items"]:
      if item["community"].getStr() == slug:
        found = true
    check found

  test "set updates the row and clear deletes it":
    # Before the fix `set` answered "new row violates row-level security policy".
    let (setOutput, setCode) = runCli(
      "set --community " & slug & " --kind session --champion 600",
      appDsn(rawDsn))
    check setCode == 0
    check parseJson(setOutput.strip())["action"].getStr() == "update"
    check database.scoped(communityId).queryOne(
      """select champion_points::text as p from rating.levels
         where community_id = $1::uuid and kind = 'session'""",
      @[textParam(communityId)]).get.get("p") == "600.00"

    let (clearOutput, clearCode) = runCli(
      "clear --community " & slug & " --kind session", appDsn(rawDsn))
    check clearCode == 0
    check parseJson(clearOutput.strip())["deleted"].getInt() == 1
    check database.scoped(communityId).queryOne(
      """select count(*)::int as n from rating.levels
         where community_id = $1::uuid""",
      @[textParam(communityId)]).get.getInt("n") == 0

  teardown:
    cleanup()
