## TL-06: the three pure helpers the import leans on. `v2Source`, `sourceToken`
## and `classicRounds` are private by default and are exported for this file
## only (D-5); nothing here needs a database.
import std/[tables, unittest]
import ../main

suite "import helpers":
  test "sourceToken strips its own prefix and keeps the id":
    check sourceToken("session:9f6a-1") == ("9f6a-1", "session")
    check sourceToken("tournament_classic:t-9") == ("t-9", "tournament_classic")
    check sourceToken("tournament_team:t-10") == ("t-10", "tournament_team")
    # A bare id is what most dumps carry; it keeps its kind empty.
    check sourceToken("1b2c3d") == ("1b2c3d", "")

  test "sourceToken strips only the prefix that matches":
    # A share code that happens to contain a prefix in the middle is an id, not
    # a second prefix; only the first match is removed.
    check sourceToken("session:tournament_team:x") ==
      ("tournament_team:x", "session")

  test "v2Source keeps manual and folds every v1 origin into a snapshot":
    check v2Source("manual") == "manual"
    for v1 in ["compat_publish", "legacy_snapshot", "generator", ""]:
      check v2Source(v1) == "legacy_snapshot"

  test "classicRounds maps every v1 round name to its bracket depth":
    check classicRounds["group"] == 0
    check classicRounds["qf"] == 1
    check classicRounds["sf"] == 2
    check classicRounds["3rd"] == 3
    check classicRounds["final"] == 4
    # A v1 round name outside this table is a bug the import must see, not a
    # default depth.
    check classicRounds.len == 5