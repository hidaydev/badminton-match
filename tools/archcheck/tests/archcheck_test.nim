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

  test "domain cannot import the database":
    let found = violationsFor("modules/session/domain/x.nim", "import db/db\n")
    check found.len == 1
    check found[0].contains("database layer")

  test "now() is rejected outside the clock":
    let found = violationsFor("modules/session/x.nim", "let t = now()\n")
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

  test "SQL with community_id passes":
    check violationsFor("modules/session/x.nim",
      "let q = \"select id from session.sessions where community_id = $1\"\n").len == 0
