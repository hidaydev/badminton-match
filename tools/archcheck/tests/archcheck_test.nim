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

  test "a module test may read the wall clock":
    check violationsFor("modules/session/tests/x_test.nim",
      "let t = epochTime()\n").len == 0

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
