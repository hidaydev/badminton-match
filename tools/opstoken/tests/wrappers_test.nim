## TL-12: the four thin operator wrappers.
##
## Each `main()` reads `paramStr` and every refusal ends the process, so a case
## is one run of the compiled wrapper with its exit code and message read back.
## `./task check` compiles suites and never builds the tools, so the four are
## built once here into a temp directory whose nimcache they share.
##
## The cases that need a database run against `MAJADU_PG_DSN`, which both gates
## require. Every row this suite writes is tagged with the process id and removed
## in teardown. `janitorcli` is driven with one ticket past the window and one
## inside it, so the boundary is proven instead of assumed.
##
## The suite lives under `tools/opstoken` because it covers the `opstoken`
## wrapper plus the three neighbours, and there is no shared `tools/wrappers`
## directory to host it.
import std/[json, options, os, osproc, strtabs, strutils, unittest]

import account/domain/lifecycle
import db/db
import sha256

const
  # Every subject, token name and ticket this suite writes starts with this, so
  # teardown can name exactly what it owns.
  tag = "tl12-"
  # The four wrappers, by the directory that holds their `main.nim`.
  wrappers = ["opstoken", "accountlifecycle", "auditretention", "janitorcli"]

proc repoRoot(): string =
  ## The tools are built from the repository root so `config.nims` supplies the
  ## module paths.
  var dir = currentSourcePath().parentDir
  for _ in 0 ..< 8:
    if fileExists(dir / "tools/opstoken/main.nim"):
      return dir
    let parent = parentDir(dir)
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot find the repository root from " & currentSourcePath())

var builtBinary: seq[(string, string)]

proc toolBinary(name: string): string =
  for (known, path) in builtBinary:
    if known == name:
      return path
  let root = repoRoot()
  var directory {.global.}: string
  if directory.len == 0:
    directory = getTempDir() / ("majadu-wrappers-" & $getCurrentProcessId())
    createDir(directory)
  let target = directory / name
  # One nimcache for all four: the shared modules compile once, not four times.
  let (output, code) = execCmdEx("nim c --hints:off --nimcache:" &
    quoteShell(directory / "nimcache") & " -o:" & quoteShell(target) & " " &
    quoteShell(root / "tools" / name / "main.nim"), workingDir = root)
  if code != 0 or not fileExists(target):
    raise newException(IOError, "cannot build " & name & ":\n" & output)
  builtBinary.add((name, target))
  target

proc runTool(name, arguments: string): tuple[output: string, exitCode: int] =
  execCmdEx(quoteShell(toolBinary(name)) & " " & arguments, workingDir = repoRoot())

proc withoutVariables(keys: openArray[string]): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for (key, value) in envPairs():
    var keep = true
    for skipped in keys:
      if key == skipped:
        keep = false
    if keep:
      result[key] = value

proc runWithoutDsn(name, arguments: string):
    tuple[output: string, exitCode: int] =
  ## An argument complaint must not depend on a database being reachable, so the
  ## connection strings are stripped: a tool that opened the database first
  ## would report the missing DSN instead.
  execCmdEx(quoteShell(toolBinary(name)) & " " & arguments,
    workingDir = repoRoot(),
    env = withoutVariables(["MAJADU_PG_DSN", "MAJADU_AUDIT_DSN"]))

var
  database: Db
  writtenUserIds: seq[string]

proc insertUser(sub: string, platformOwner: bool): string =
  result = database.queryOne(
    """insert into platform.user (google_sub, email_hash, display_name,
                                  is_platform_owner)
       values ($1, $2, $1, $3) returning id""",
    @[textParam(sub), textParam(sha256Hex(sub)), boolParam(platformOwner)]
    ).get.get("id")
  writtenUserIds.add(result)

proc countOf(sql: string, params: seq[DbParam] = @[]): int =
  parseInt(database.queryOne(sql, params).get.get("n"))

proc auditCount(action, targetId: string): int =
  countOf("select count(*) as n from account.audit where action = $1 and target_id = $2",
    @[textParam(action), textParam(targetId)])

proc configInt(key: string): int =
  parseJson(database.queryOne(
    "select value::text as value from platform.config where key = $1",
    @[textParam(key)]).get.get("value")).getInt()

proc cleanup() =
  # Audit first: it carries no foreign key, so a stale row would outlive the
  # account it names. `ids` is a comma-joined list of uuids the database
  # generated for this suite.
  if writtenUserIds.len > 0:
    let ids = textParam(writtenUserIds.join(","))
    discard database.execUpdate(
      """delete from account.audit
         where actor_id::text = any(string_to_array($1, ','))
            or target_id = any(string_to_array($1, ','))""", @[ids])
  discard database.execUpdate(
    "delete from platform.ops_token where name like $1", @[textParam(tag & "%")])
  discard database.execUpdate(
    """delete from platform.ws_ticket
       where encode(token_hash, 'hex') in ($1, $2)""",
    @[textParam(sha256Hex(tag & "expired-ticket")),
      textParam(sha256Hex(tag & "live-ticket"))])
  if writtenUserIds.len > 0:
    discard database.execUpdate(
      "delete from platform.user where id::text = any(string_to_array($1, ','))",
      @[textParam(writtenUserIds.join(","))])
  writtenUserIds.setLen(0)

suite "thin wrapper CLIs":
  setup:
    let dsn = getEnv("MAJADU_PG_DSN")
    if dsn.len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    database = openDb(dsn, 1)
    cleanup()

  teardown:
    cleanup()
    database.close()

  test "opstoken without a command prints the usage block and exits 2":
    let run = runWithoutDsn("opstoken", "")
    check run.exitCode == 2
    check run.output.contains("Usage: opstoken <create|list|revoke> [options]")
    check run.output.contains("Requires MAJADU_PG_DSN.")

  test "opstoken refuses an unknown command":
    let run = runTool("opstoken", "nope")
    check run.exitCode == 2
    check run.output.contains("unknown command: nope")

  test "a non-numeric --days is refused before the database is opened":
    # `main` reports this one with `fail`, so the code is 1, not the usage 2.
    let run = runWithoutDsn("opstoken", "create --name x --days x")
    check run.exitCode == 1
    check run.output.contains("--days is not a number: x")
    check not run.output.contains("MAJADU_PG_DSN")

  test "create without --name is a usage failure, not a missing DSN":
    # The check sits above `openDb`, so the complaint names the flag even when
    # nothing could have been connected.
    let run = runWithoutDsn("opstoken", "create")
    check run.exitCode == 2
    check run.output.contains("create needs --name")
    check not run.output.contains("MAJADU_PG_DSN")

  test "create refuses a subject nobody owns":
    let run = runTool("opstoken", "create --name " & tag &
      "ghost --sub " & tag & "nobody")
    check run.exitCode == 1
    check run.output.contains("no user with sub " & tag & "nobody")
    check countOf("select count(*) as n from platform.ops_token where name = $1",
      @[textParam(tag & "ghost")]) == 0

  test "create refuses a subject that is not a platform owner":
    discard insertUser(tag & "plain", false)
    let run = runTool("opstoken", "create --name " & tag &
      "denied --sub " & tag & "plain")
    check run.exitCode == 1
    check run.output.contains("only a platform owner may issue ops tokens")
    check countOf("select count(*) as n from platform.ops_token where name = $1",
      @[textParam(tag & "denied")]) == 0
    check auditCount("platform.ops_token.create", tag & "denied") == 0

  test "create from an owner stores the hash and writes one audit row":
    let owner = insertUser(tag & "owner", true)
    let name = tag & "issued"
    let run = runTool("opstoken", "create --name " & name & " --sub " &
      tag & "owner --days 7")
    check run.exitCode == 0
    let payload = parseJson(run.output)
    let token = payload["token"].getStr()
    check token.len >= 40
    check payload["name"].getStr() == name
    check payload["expiresInDays"].getInt() == 7
    let stored = database.queryOne(
      """select encode(token_hash, 'hex') as hash, created_by::text as created_by
         from platform.ops_token where name = $1""", @[textParam(name)]).get
    # The printed token is the only copy: the row keeps its hash.
    check stored.get("hash") == sha256Hex(token)
    check stored.get("created_by") == owner
    check auditCount("platform.ops_token.create", name) == 1
    check database.queryOne(
      """select actor_id::text as actor, actor_role
         from account.audit
         where action = 'platform.ops_token.create' and target_id = $1""",
      @[textParam(name)]).get.get("actor") == owner

  test "revoke needs an id and only revokes once":
    discard insertUser(tag & "owner", true)
    let name = tag & "revoked"
    check runTool("opstoken", "create --name " & name & " --days 0").exitCode == 0
    let missing = runTool("opstoken", "revoke")
    check missing.exitCode == 2
    check missing.output.contains("revoke needs --id")
    let tokenId = database.queryOne(
      "select id::text as id from platform.ops_token where name = $1",
      @[textParam(name)]).get.get("id")
    let first = runTool("opstoken", "revoke --id " & tokenId)
    check first.exitCode == 0
    check parseJson(first.output)["revoked"].getStr() == tokenId
    let second = runTool("opstoken", "revoke --id " & tokenId)
    check second.exitCode == 1
    check second.output.contains("token not found or already revoked")
    check database.queryOne(
      """select revoked_at is not null as revoked from platform.ops_token
         where id = $1::uuid""", @[textParam(tokenId)]).get.get("revoked") == "t"

  test "accountlifecycle without a subcommand prints the usage block":
    let run = runWithoutDsn("accountlifecycle", "")
    check run.exitCode == 2
    check run.output.contains("Usage: accountlifecycle anonymize --sub")

  test "anonymize needs both --sub and --actor before the database is opened":
    let run = runWithoutDsn("accountlifecycle", "anonymize --sub " & tag & "victim")
    check run.exitCode == 2
    check run.output.contains("anonymize needs --sub and --actor")
    check not run.output.contains("MAJADU_PG_DSN")

  test "anonymize refuses a subject nobody owns":
    let run = runTool("accountlifecycle", "anonymize --sub " & tag &
      "ghost --actor " & tag & "owner")
    check run.exitCode == 1
    check run.output.contains("no user with sub " & tag & "ghost")

  test "anonymize rewrites the named account and records the actor":
    let victim = insertUser(tag & "victim", false)
    let actor = insertUser(tag & "owner", true)
    let run = runTool("accountlifecycle", "anonymize --sub " & tag &
      "victim --actor " & tag & "owner")
    check run.exitCode == 0
    check parseJson(run.output)["anonymized"].getStr() == tag & "victim"
    let row = database.queryOne(
      """select google_sub, email_hash, display_name from platform.user
         where id = $1::uuid""", @[textParam(victim)]).get
    check row.get("google_sub") == sha256Hex(tag & "victim")
    check row.get("email_hash") == marker(victim)
    check isAnonymized(row.get("email_hash"), victim)
    check row.get("display_name").len == 0
    check auditCount("account.anonymize", victim) == 1
    check database.queryOne(
      """select actor_id::text as actor from account.audit
         where action = 'account.anonymize' and target_id = $1""",
      @[textParam(victim)]).get.get("actor") == actor

  test "auditretention refuses to run without its own DSN":
    let run = runWithoutDsn("auditretention", "")
    check run.exitCode == 1
    check run.output.contains(
      "MAJADU_AUDIT_DSN is required (owner role, not bm2_app)")

  test "auditretention honours --dsn and purges exactly the expired window":
    let days = configInt("audit.retention_days")
    let window = """select count(*) as n from account.audit
                    where occurred_at < now() - make_interval(days => $1)"""
    let before = countOf(window, @[intParam(days.int64)])
    let run = runWithoutDsn("auditretention",
      "--dsn " & quoteShell(getEnv("MAJADU_PG_DSN")))
    check run.exitCode == 0
    let payload = parseJson(run.output)
    check payload["retentionDays"].getInt() == days
    check payload["deleted"].getInt() == before
    # A re-read states the purge happened against that window.
    check countOf(window, @[intParam(days.int64)]) == 0

  test "janitor refuses to run without a connection string":
    let run = runWithoutDsn("janitorcli", "")
    check run.exitCode == 1
    check run.output.contains("MAJADU_PG_DSN is required")

  test "janitor purges past the window, keeps live rows and reports it":
    let days = configInt("janitor.retention_days")
    let expired = sha256Hex(tag & "expired-ticket")
    let live = sha256Hex(tag & "live-ticket")
    discard database.execUpdate(
      """insert into platform.ws_ticket
           (token_hash, channel_kind, channel_id, expires_at)
         values (decode($1, 'hex'), 'share', gen_random_uuid(),
                 now() - make_interval(days => $2))""",
      @[textParam(expired), intParam((days + 2).int64)])
    discard database.execUpdate(
      """insert into platform.ws_ticket
           (token_hash, channel_kind, channel_id, expires_at)
         values (decode($1, 'hex'), 'share', gen_random_uuid(),
                 now() + make_interval(days => 2))""",
      @[textParam(live)])
    let before = countOf(
      """select count(*) as n from platform.ws_ticket
         where expires_at < now() - make_interval(days => $1)""",
      @[intParam(days.int64)])
    let run = runTool("janitorcli", "")
    check run.exitCode == 0
    let payload = parseJson(run.output)
    check payload["retentionDays"].getInt() == days
    var names: seq[string] = @[]
    var sum = 0
    var tickets = -1
    for entry in payload["tables"]:
      names.add entry["table"].getStr()
      sum += entry["deleted"].getInt()
      if entry["table"].getStr() == "platform.ws_ticket":
        tickets = entry["deleted"].getInt()
    check names == @["auth.oauth_flows", "platform.idempotency_keys",
      "platform.outbox", "session.links", "account.sessions",
      "community.invite", "platform.ops_token", "platform.ws_ticket"]
    check payload["deleted"].getInt() == sum
    check tickets == before
    check countOf(
      "select count(*) as n from platform.ws_ticket where encode(token_hash, 'hex') = $1",
      @[textParam(expired)]) == 0
    check countOf(
      "select count(*) as n from platform.ws_ticket where encode(token_hash, 'hex') = $1",
      @[textParam(live)]) == 1

  test "every wrapper builds from its own directory":
    # The list is the scope statement: a renamed tool breaks this line instead
    # of silently dropping out of the suite.
    for name in wrappers:
      check fileExists(toolBinary(name))