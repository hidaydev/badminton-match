import std/[strutils, unittest]
import ../rules

suite "archcheck rules":
  test "clean module passes":
    check violationsFor("modules/session/domain/session.nim",
      "import std/options\nproc f*(): int = 1\n").len == 0

  test "module cannot import the delivery layer":
    let found = violationsFor("modules/session/x.nim", "import apps/api/src/server\n")
    check found.len == 1
    check found[0].contains("delivery layer")

  test "module cannot reach the delivery layer by its path alias":
    let found = violationsFor("modules/session/x.nim",
      "import api/src/routes_gen\n")
    check found.len == 1
    check found[0].contains("delivery layer")

  test "a module test may read the route table":
    let found = violationsFor("modules/account/tests/x_test.nim",
      "import api/src/routes_gen\n")
    check found.len == 0

  test "domain cannot import the database":
    let found = violationsFor("modules/session/domain/x.nim", "import db/db\n")
    check found.len == 1
    check found[0].contains("database layer")

  test "platform cannot import a feature module":
    # BE-19: the primitive layer must not depend on a feature, or the graph
    # becomes cyclic the day a feature needs platform in return.
    let found = violationsFor("modules/platform/config/x.nim",
      "import session/scoring\n")
    check found.len == 1
    check found[0].contains("feature module")

  test "platform may still import the shared driver and its own files":
    check violationsFor("modules/platform/config/x.nim",
      "import db/db\nimport scoring_presets\n").len == 0

  test "now() is rejected outside the clock":
    let found = violationsFor("modules/session/x.nim", "let t = now()\n")
    check found.len == 1
    check found[0].contains("clock.utcNow")

  test "epochTime() is rejected outside the clock":
    let found = violationsFor("modules/session/x.nim", "let t = epochTime()\n")
    check found.len == 1
    check found[0].contains("clock.utcNow")

  test "the clock module may read the system clock":
    check violationsFor("shared/platform-lib/clock.nim",
      "let a = now()\nlet b = epochTime()\n").len == 0

  test "a test support file may read the wall clock":
    check violationsFor("modules/session/tests/x_support.nim",
      "let t = epochTime()\n").len == 0

  test "a _test.nim may not read the wall clock directly":
    let found = violationsFor("modules/session/tests/x_test.nim",
      "let t = epochTime()\n")
    check found.len == 1
    check found[0].contains("clock.utcNow")

  test "a _test.nim may not call now() either":
    let found = violationsFor("apps/api/tests/integration/x_test.nim",
      "let t = now()\n")
    check found.len == 1
    check found[0].contains("clock.utcNow")

  test "environment access is rejected in modules":
    let found = violationsFor("modules/session/x.nim", "let v = getEnv(\"X\")\n")
    check found.len == 1
    check found[0].contains("process edge")

  test "SQL touching domain tables needs community_id":
    let found = violationsFor("modules/session/x.nim",
      "let q = \"select id from session.sessions where id = $1\"\n")
    check found.len == 1
    check found[0].contains("community_id")

  test "SQL now() inside a literal is not a clock call":
    check violationsFor("apps/api/src/app.nim",
      "let q = \"update t set a = now() where id = $1\"\n").len == 0

  test "infrastructure adapters may read the environment":
    check violationsFor("modules/account/infrastructure/oidc.nim",
      "let v = getEnv(\"OIDC_CLIENT_ID\")\n").len == 0

  test "SQL with community_id passes":
    check violationsFor("modules/session/x.nim",
      "let q = \"select id from session.sessions where community_id = $1\"\n").len == 0

  test "a statement split around a shared constant keeps its scope":
    let source = "const cols* = \"score_a = null, score_b = null\"\n" &
      "let q = \"update session.games set status = $3, \" & cols & \" where community_id = $1\"\n"
    check violationsFor("modules/session/x.nim", source).len == 0

  test "two separate statements do not merge into one scope":
    let source = "let bad = \"select id from session.sessions where id = $1\"\n" &
      "let ok = \"select id from session.sessions where community_id = $1\"\n"
    let found = violationsFor("modules/session/x.nim", source)
    check found.len == 1
    check found[0].contains("community_id")

  test "the delivery layer is scanned for community scope":
    let found = violationsFor("apps/api/src/app.nim",
      "let q = \"select id from session.sessions where id = $1\"\n")
    check found.len == 1
    check found[0].contains("app.nim:1")
    check found[0].contains("community_id")

  test "a verb that is not the first word still marks SQL":
    # The old rule only read literals that began with the verb, so a leading
    # comment or a fragment hid the statement from the scan.
    let comment = violationsFor("apps/api/src/app.nim",
      "let q = \"-- one row\\nupdate session.games set status = $2 where id = $1\"\n")
    check comment.len == 1
    check comment[0].contains("community_id")
    let fragment = violationsFor("apps/api/src/app.nim",
      "let q = \" or exists (select 1 from player.aliases a)\"\n")
    check fragment.len == 1
    check fragment[0].contains("community_id")

  test "a statement built as base & fragment is judged as one statement":
    let source = "let base = \"select id from session.sessions\"\n" &
      "let q = base & \" where id = $1\"\n"
    let found = violationsFor("apps/api/src/app.nim", source)
    check found.len == 1
    check found[0].contains("community_id")

  test "a SET fragment split from its where clause stays unscoped":
    let source = "let q = \"update session.games set status = $2\" &\n" &
      "  \" where id = $1\"\n"
    let found = violationsFor("modules/session/x.nim", source)
    check found.len == 1
    check found[0].contains("community_id")

  test "community_id in an unrelated subquery does not scope the table":
    let source = "let q = \"select id from session.sessions s where s.id = $1\" &\n" &
      "  \" and exists (select 1 from community.membership m\" &\n" &
      "  \" where m.community_id = $2)\"\n"
    let found = violationsFor("apps/api/src/app.nim", source)
    check found.len == 1
    check found[0].contains("community_id")

  test "an uncorrelated subquery must scope itself":
    let source = "let q = \"select id from session.sessions s\" &\n" &
      "  \" where s.community_id = $1 and exists\" &\n" &
      "  \" (select 1 from player.aliases a where a.alias_key = $2)\"\n"
    let found = violationsFor("modules/player/store.nim", source)
    check found.len == 1
    check found[0].contains("community_id")

  test "a correlated subquery inherits the outer scope":
    let source = "let q = \"select p.id from session.participants p\" &\n" &
      "  \" where p.community_id = $1 and not exists\" &\n" &
      "  \" (select 1 from session.participants t\" &\n" &
      "  \" where t.session_id = p.session_id)\"\n"
    check violationsFor("modules/player/merge.nim", source).len == 0

  test "a join predicate alone does not scope the delivery layer":
    let source = "let q = \"select p.id from player.players p\" &\n" &
      "  \" join session.participants s\" &\n" &
      "  \" on s.community_id = p.community_id\"\n"
    let found = violationsFor("apps/api/src/app.nim", source)
    check found.len == 1
    check found[0].contains("community_id")

  test "community_id compared with itself is not a scope":
    let source = "let q = \"select id from session.sessions\" &\n" &
      "  \" where community_id = community_id\"\n"
    check violationsFor("apps/api/src/app.nim", source).len == 1

  test "each union branch must scope itself":
    let source = "let q = \"select id from session.sessions where community_id = $1\" &\n" &
      "  \" union all select id from player.players\"\n"
    let found = violationsFor("modules/rating/read.nim", source)
    check found.len == 1
    check found[0].contains("community_id")

  test "a builder accumulates its fragments into one statement":
    # `sql.add` reaches the database with the base, so the scope in the base
    # covers the fragment. Judging the fragment alone would be a false alarm.
    let scoped = "var sql = \"select id from session.sessions where community_id = $1\"\n" &
      "sql.add(\" and title = $2\")\n"
    check violationsFor("modules/session/write.nim", scoped).len == 0
    let unscoped = "var sql = \"select id from session.sessions\"\n" &
      "sql.add(\" and title = $2\")\n"
    check violationsFor("modules/session/write.nim", unscoped).len >= 1

  test "a chain that starts at an identifier is not also judged as a fragment":
    let source = "const tail = \" and exists (select 1 from player.aliases a\" &\n" &
      "  \" where a.community_id = p.community_id and a.player_id = p.id)\"\n" &
      "let q = \"select p.id from player.players p where p.community_id = $1\" & tail\n"
    check violationsFor("modules/player/store.nim", source).len == 0

  test "a cte joined on community_id carries its scope into the join":
    let source = "let q = \"with m as (select id, community_id from tournament.team_matches\" &\n" &
      "  \" where community_id = $1) select tp.id from m\" &\n" &
      "  \" join tournament.team_players tp on tp.community_id = m.community_id\"\n"
    check violationsFor("modules/rating/read.nim", source).len == 0

  test "a builder whose base alone is unscoped is still reported":
    # The fragment is in another branch (or another proc with the same name);
    # an append may not be the only predicate the base relies on.
    let branched = "proc a() =\n" &
      "  var sql = \"select id from session.sessions\"\n" &
      "proc b() =\n" &
      "  var sql = \"select id from player.players\"\n" &
      "  sql.add(\" where community_id = $1\")\n"
    check violationsFor("modules/session/write.nim", branched).len >= 1
    let conditional = "proc a(flag: bool) =\n" &
      "  var sql = \"select id from session.sessions\"\n" &
      "  if flag:\n" &
      "    sql.add(\" where community_id = $1\")\n"
    check violationsFor("modules/session/write.nim", conditional).len == 1

  test "a set operator other than union also splits the statement":
    let source = "let q = \"select id from session.sessions where community_id = $1\" &\n" &
      "  \" except select id from player.players\"\n"
    check violationsFor("modules/rating/read.nim", source).len == 1

  test "a cte over a non-domain table does not lend a scope it never proved":
    let source = "let q = \"with m as (select community_id from import.row_map)\" &\n" &
      "  \" select s.id from session.sessions s\" &\n" &
      "  \" join m on s.community_id = m.community_id\"\n"
    check violationsFor("apps/api/src/app.nim", source).len == 1

  test "a scoped lookup subquery binds community_id":
    let source = "let q = \"select id from session.sessions\" &\n" &
      "  \" where community_id = (select id from platform.community where slug = $1)\"\n"
    check violationsFor("modules/session/write.nim", source).len == 0

  test "an insert is scoped by its column list":
    check violationsFor("apps/api/src/app.nim",
      "let q = \"insert into player.players (community_id, canonical_name)\" &\n" &
      "  \" values ($1, $2)\"\n").len == 0

  test "the community allowlist exempts one routine":
    let source = "proc handler(q: string) =\n" &
      "  let sql = \"select id from session.sessions where id = $1\"\n"
    check violationsFor("apps/api/src/app.nim", source).len == 1
    check violationsFor("apps/api/src/app.nim", source,
      ["apps/api/src/app.nim:handler"]).len == 0
    check violationsFor("apps/api/src/app.nim", source,
      ["apps/api/src/app.nim:other"]).len == 1

  test "one allowlist entry exempts the whole tools tree":
    let source = "let q = \"select id from session.sessions where id = $1\"\n"
    check violationsFor("tools/import/main.nim", source).len == 1
    check violationsFor("tools/import/main.nim", source, ["tools/"]).len == 0

  test "a scan below the file floor is a violation":
    check scanFloorViolation(0, 50).contains("partial checkout")
    check scanFloorViolation(49, 50).contains("below the 50 file floor")
    check scanFloorViolation(50, 50).len == 0
    check scanFloorViolation(177, 50).len == 0

suite "honest test rules":
  test "a block with a check is not reported":
    let source = "  test \"x\":\n    check 1 == 1\n"
    check honestTestViolations("modules/session/tests/x_test.nim", source).len == 0

  test "a block without an assertion is reported":
    let source = "  test \"does nothing\":\n    let a = 1\n    discard a\n"
    let found = honestTestViolations("modules/session/tests/x_test.nim", source)
    check found.len == 1
    check found[0].contains("R-01")
    check found[0].contains("does nothing")

  test "a flush-left fixture inside the block does not hide the checks after it":
    ## The JSON body of a triple-quoted fixture can start at column zero. That
    ## line is not code, so it must not close the test before its assertions:
    ## the report used to name a test full of checks as empty.
    let source = "  test \"x\":\n" &
      "    let body = \"\"\"\n" &
      "{\n" &
      "  \"status\": 1\n" &
      "}\n" &
      "\"\"\"\n" &
      "    check body.len > 0\n"
    let found = honestTestViolations("modules/session/tests/x_test.nim", source)
    check found.len == 0

  test "a check inside a nested proc does not count":
    let source = "  test \"x\":\n" &
      "    proc helper() =\n" &
      "      check 1 == 1\n" &
      "    helper()\n"
    let found = honestTestViolations("modules/session/tests/x_test.nim", source)
    check found.len == 1
    check found[0].contains("R-01")

  test "a call to an asserting helper counts as the block's assertion":
    let helper = "proc expectProblem*(status: int) =\n  check status == 404\n"
    check assertingRoutines(helper) == @["expectProblem"]
    let source = "  test \"x\":\n    expectProblem(404)\n"
    check honestTestViolations("modules/session/tests/x_test.nim", source,
      [], ["expectProblem"]).len == 0

  test "check true is always reported":
    let inline = honestTestViolations("modules/session/tests/x_test.nim",
      "  test \"x\": check true\n")
    check inline.len == 1
    check inline[0].contains("R-02")
    let nested = honestTestViolations("modules/session/tests/x_test.nim",
      "  test \"x\":\n    check true\n")
    check nested.len == 1
    check nested[0].contains("`check true`")

  test "check false is allowed only inside an else arm":
    let source = "  test \"x\":\n" &
      "    if true:\n" &
      "      check false\n" &
      "    else:\n" &
      "      check false\n"
    let found = honestTestViolations("modules/session/tests/x_test.nim", source)
    check found.len == 1
    check found[0].contains("x_test.nim:3")

  test "an identifier compared with itself is vacuous":
    let source = "  test \"x\":\n" &
      "    let a = 1\n" &
      "    check a == a\n" &
      "    check len(\"a\") >= 0\n"
    let found = honestTestViolations("modules/session/tests/x_test.nim", source)
    check found.len == 2
    check found[0].contains("compares an identifier with itself")
    check found[1].contains("true for every value")

  test "a meaningful comparison is not flagged":
    let source = "  test \"x\":\n" &
      "    let a = 1\n" &
      "    let b = 2\n" &
      "    check a == b\n" &
      "    check a.len >= 1\n"
    check honestTestViolations("modules/session/tests/x_test.nim", source).len == 0

  test "the allowlist exempts one block and not the next":
    let source = "  test \"allowed\":\n    check true\n" &
      "  test \"new\":\n    check true\n"
    let found = honestTestViolations("modules/session/tests/x_test.nim", source,
      ["modules/session/tests/x_test.nim:allowed"])
    check found.len == 1
    check found[0].contains("x_test.nim:4")
    check honestTestViolations("modules/session/tests/x_test.nim", source,
      ["modules/session/tests/x_test.nim"]).len == 0

suite "delivery SQL rule":
  test "SQL in a handler is a finding":
    let source = "proc handler() =\n" &
      "  let sql = \"select id from session.sessions where community_id = $1\"\n"
    let found = deliverySqlViolations("apps/api/src/app.nim", source)
    check found.len == 1
    check found[0].contains("move it to modules/<name>/application")

  test "one routine entry exempts its SQL and application.db":
    let source = "proc handler() =\n" &
      "  discard application.db.execUpdate(\n" &
      "    \"delete from platform.idempotency_keys where key = $1\")\n"
    check deliverySqlViolations("apps/api/src/app.nim", source).len == 2
    check deliverySqlViolations("apps/api/src/app.nim", source,
      ["apps/api/src/app.nim:handler"]).len == 0

  test "a new routine in an allowlisted file is still a finding":
    let source = "proc old() =\n" &
      "  let sql = \"select id from session.sessions where community_id = $1\"\n" &
      "proc fresh() =\n" &
      "  let sql = \"select id from player.players where community_id = $1\"\n"
    let found = deliverySqlViolations("apps/api/src/app.nim", source,
      ["apps/api/src/app.nim:old"])
    check found.len == 1
    check found[0].contains("fresh")

  test "a module and a test file are outside the rule":
    let source = "let sql = \"select id from session.sessions where community_id = $1\"\n"
    check deliverySqlViolations("modules/session/write.nim", source).len == 0
    check deliverySqlViolations("apps/api/tests/x_test.nim", source).len == 0

  test "a directory or whole-file entry exempts the tree":
    let source = "proc handler() =\n" &
      "  discard application.db.execUpdate(\n" &
      "    \"update platform.x set y = 1\")\n"
    check deliverySqlViolations("apps/api/src/app.nim", source,
      ["apps/api/"]).len == 0
    check deliverySqlViolations("apps/api/src/app.nim", source,
      ["apps/api/src/app.nim"]).len == 0

  test "an empty allowlist entry is ignored rather than exempting everything":
    let source = "proc handler() =\n" &
      "  let sql = \"select id from session.sessions where community_id = $1\"\n"
    check deliverySqlViolations("apps/api/src/app.nim", source,
      [""]).len == 1

  test "every SQL verb is a finding":
    for verb in ["insert into session.sessions(id)", "update session.sessions set id = 1",
                 "with x as (select 1) select * from x"]:
      let source = "proc handler() =\n  let sql = \"" & verb & "\"\n"
      check deliverySqlViolations("apps/api/src/app.nim", source).len == 1

  test "a statement outside any routine is named without a proc suffix":
    let source = "let sql = \"delete from session.sessions where community_id = $1\"\n"
    let found = deliverySqlViolations("apps/api/src/app.nim", source)
    check found.len == 1
    check not found[0].contains("(proc ")

  test "application.db is reported once per routine":
    let source = "proc handler() =\n" &
      "  discard application.db.acquire()\n" &
      "  discard application.db.release()\n"
    let found = deliverySqlViolations("apps/api/src/app.nim", source)
    check found.len == 1
    check found[0].contains("application.db")

  test "application.db inside a string literal is not the global pool":
    let source = "proc handler() =\n  echo \"application.db\"\n"
    check deliverySqlViolations("apps/api/src/app.nim", source).len == 0
