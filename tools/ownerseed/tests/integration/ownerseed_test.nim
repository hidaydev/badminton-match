## TL-14: `ownerseed` on the only instance it is written for, an empty one.
##
## `ensureOwner`, `existingOwner` and `ensureDefaultCommunity` are private and
## `main` reads `paramStr`, so every case drives the compiled tool. They also
## need an instance with no platform owner at all, which the shared test
## database never is: each case builds its own scratch database, runs the
## migrations and the config seed into it, and drops it in teardown. A seeded
## community is never touched, and neither is the shared database's contents.
##
## The audit row is written only when the owner was created, so the idempotence
## case counts rows in `account.audit`, not just `platform.user`.
import std/[algorithm, json, options, os, osproc, strtabs, strutils, unittest]

import db/db
import sha256

const
  # Named inside the scratch database, which is dropped whole, so no prefix is
  # needed here.
  sub = "tl14-owner"
  email = "owner@tl14.example"
  clubSlug = "tl14-club"
  clubName = "TL14 Club"

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  for _ in 0 ..< 8:
    if fileExists(dir / "tools/ownerseed/main.nim"):
      return dir
    let parent = parentDir(dir)
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot find the repository root from " & currentSourcePath())

proc adminDatabase(): Db =
  let dsn = getEnv("MAJADU_PG_DSN")
  if dsn.len == 0:
    raise newException(ValueError, "MAJADU_PG_DSN is required")
  openDb(dsn, 1)

proc withDatabase(dsn, name: string): string =
  ## The same credentials and host, pointed at another database.
  let question = dsn.find('?')
  let head = if question < 0: dsn else: dsn[0 ..< question]
  let tail = if question < 0: "" else: dsn[question .. ^1]
  let schemeEnd = head.find("://")
  let slash = head.rfind('/')
  if slash < 0 or slash < schemeEnd + 3:
    head & "/" & name & tail
  else:
    head[0 ..< slash] & "/" & name & tail

var builtBinary {.global.}: string

proc ownerseedBinary(): string =
  ## `./task check` compiles suites and not the tools, so the tool is built once
  ## here and reused by every case.
  if builtBinary.len > 0:
    return builtBinary
  let root = repoRoot()
  let directory = getTempDir() / ("majadu-ownerseed-" & $getCurrentProcessId())
  createDir(directory)
  let target = directory / "ownerseed"
  let (output, code) = execCmdEx("nim c --hints:off --nimcache:" &
    quoteShell(directory / "nimcache") & " -o:" & quoteShell(target) & " " &
    quoteShell(root / "tools/ownerseed/main.nim"), workingDir = root)
  if code != 0 or not fileExists(target):
    raise newException(IOError, "cannot build ownerseed:\n" & output)
  builtBinary = target
  target

proc sqlFiles(directory: string): seq[string] =
  for path in walkFiles(directory / "*.sql"):
    result.add(path)
  result.sort()

var
  scratch: string
  scratchDsn: string
  fresh: Db

proc runTool(arguments: string): tuple[output: string, exitCode: int] =
  var environment = newStringTable(modeCaseSensitive)
  for (key, value) in envPairs():
    if key != "MAJADU_PG_DSN":
      environment[key] = value
  environment["MAJADU_PG_DSN"] = scratchDsn
  execCmdEx(quoteShell(ownerseedBinary()) & " " & arguments,
    workingDir = repoRoot(), env = environment)

proc countOf(sql: string, params: seq[DbParam] = @[]): int =
  parseInt(fresh.queryOne(sql, params).get.get("n"))

proc registryTimezone(): string =
  parseJson(fresh.queryOne(
    "select value::text as value from platform.config where key = $1",
    @[textParam("community.default_timezone")]).get.get("value")).getStr()

proc removeConfig(key: string): string =
  ## The whole row as JSON, so the restore puts every column back.
  result = fresh.queryOne(
    """select to_jsonb(entry)::text as row from platform.config entry
       where key = $1""", @[textParam(key)]).get.get("row")
  discard fresh.execUpdate("delete from platform.config where key = $1",
    @[textParam(key)])

proc restoreConfig(row: string) =
  discard fresh.execUpdate(
    """insert into platform.config
       select * from jsonb_populate_record(null::platform.config, $1::jsonb)""",
    @[textParam(row)])

proc dropScratch(admin: Db) =
  ## `drop ... if exists` would still print its NOTICE on every case, so the
  ## catalogue is asked first.
  if admin.queryOne(
      "select 1 as present from pg_database where datname = $1",
      @[textParam(scratch)]).isSome:
    discard admin.execUpdate("drop database " & scratch & " with (force)")

suite "ownerseed":
  setup:
    scratch = "bm2_scratch_tl14_" & $getCurrentProcessId()
    scratchDsn = withDatabase(getEnv("MAJADU_PG_DSN"), scratch)
    let admin = adminDatabase()
    try:
      dropScratch(admin)
      discard admin.execUpdate("create database " & scratch)
    finally:
      admin.close()
    fresh = openDb(scratchDsn, 1)
    # `dbtools migrate` applies every pending file inside one transaction, so
    # the same shape is used here.
    discard fresh.txRet(proc(conn: DbConn): int =
      for path in sqlFiles(repoRoot() / "db/migrations"):
        conn.execScript(readFile(path))
      for path in sqlFiles(repoRoot() / "db/seeds"):
        conn.execScript(readFile(path))
      0)

  teardown:
    fresh.close()
    let admin = adminDatabase()
    try:
      dropScratch(admin)
    finally:
      admin.close()

  test "--dry-run reports an empty instance and writes nothing":
    let run = runTool("--dry-run --sub " & sub & " --email " & email)
    check run.exitCode == 0
    let payload = parseJson(run.output)
    check payload["dryRun"].getBool()
    check payload["ownerExists"].getBool() == false
    check payload["communityExists"].getBool() == false
    check countOf("select count(*) as n from platform.user") == 0
    check countOf("select count(*) as n from platform.community") == 0
    check countOf("select count(*) as n from account.audit") == 0

  test "a missing --email on a fresh instance exits 2 and writes nothing":
    let run = runTool("--sub " & sub & " --community-slug " & clubSlug)
    check run.exitCode == 2
    check run.output.contains("--email is required when creating the owner")
    check countOf("select count(*) as n from platform.user") == 0
    check countOf("select count(*) as n from account.audit") == 0

  test "a missing community timezone fails the run and creates no community":
    # `ensureDefaultCommunity` takes the timezone from the config registry and
    # refuses to invent one, so removing the key stops the run.
    let saved = removeConfig("community.default_timezone")
    check saved.len > 0
    let run = runTool("--sub " & sub & " --email " & email &
      " --community-slug " & clubSlug)
    check run.exitCode == 1
    check run.output.contains("missing key: community.default_timezone")
    check countOf("select count(*) as n from platform.community where slug = $1",
      @[textParam(clubSlug)]) == 0
    restoreConfig(saved)
    check countOf(
      "select count(*) as n from platform.config where key = $1",
      @[textParam("community.default_timezone")]) == 1
    check registryTimezone().len > 0

  test "an email already attached to another subject is refused":
    discard fresh.execUpdate(
      """insert into platform.user (google_sub, email_hash, display_name)
         values ($1, $2, 'Other')""",
      @[textParam("other-subject"), textParam(sha256Hex(email))])
    let run = runTool("--sub " & sub & " --email " & email)
    check run.exitCode == 1
    check run.output.contains("email already belongs to other-subject")
    check countOf(
      "select count(*) as n from platform.user where is_platform_owner") == 0
    check countOf("select count(*) as n from account.audit") == 0

  test "a first run creates one owner, one audit row and the community":
    let run = runTool("--sub " & sub & " --email " & email &
      " --community-slug " & clubSlug & " --community-name \"" & clubName & "\"")
    check run.exitCode == 0
    let payload = parseJson(run.output)
    check payload["seeded"].getBool()
    let ownerId = payload["ownerId"].getStr()
    check ownerId.len == 36
    check payload["communityId"].getStr().len == 36
    check countOf(
      "select count(*) as n from platform.user where is_platform_owner") == 1
    let owner = fresh.queryOne(
      """select id::text as id, email_hash, display_name
         from platform.user where google_sub = $1""", @[textParam(sub)]).get
    check owner.get("id") == ownerId
    check owner.get("email_hash") == sha256Hex(email)
    let audit = fresh.queryOne(
      """select actor_id::text as actor, actor_role, target_kind, target_id
         from account.audit where action = 'platform.owner.bootstrap'""")
    check audit.isSome
    check audit.get.get("actor") == ownerId
    check audit.get.get("actor_role") == "platform_owner"
    check audit.get.get("target_kind") == "user"
    check audit.get.get("target_id") == ownerId
    check countOf(
      "select count(*) as n from account.audit where action = 'platform.owner.bootstrap'") == 1
    let community = fresh.queryOne(
      """select timezone from platform.community where slug = $1""",
      @[textParam(clubSlug)]).get
    check community.get("timezone") == registryTimezone()

  test "a second run with the same --sub adds no user and no audit row":
    check runTool("--sub " & sub & " --email " & email &
      " --community-slug " & clubSlug).exitCode == 0
    let second = runTool("--sub " & sub & " --email " & email &
      " --community-slug " & clubSlug)
    check second.exitCode == 0
    check parseJson(second.output)["seeded"].getBool()
    check countOf("select count(*) as n from platform.user") == 1
    check countOf(
      "select count(*) as n from account.audit where action = 'platform.owner.bootstrap'") == 1
    check countOf("select count(*) as n from platform.community") == 1

  test "a second run with a different --sub names the existing owner":
    check runTool("--sub " & sub & " --email " & email &
      " --community-slug " & clubSlug).exitCode == 0
    let run = runTool("--sub other-subject --email other@tl14.example")
    check run.exitCode == 1
    check run.output.contains("this instance already has a platform owner (" &
      sub & ")")
    check countOf(
      "select count(*) as n from platform.user where is_platform_owner") == 1
    check countOf(
      "select count(*) as n from platform.user where google_sub = $1",
      @[textParam("other-subject")]) == 0