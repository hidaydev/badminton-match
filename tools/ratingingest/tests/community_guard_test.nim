import std/unittest
import ../main

## The guard that catches a wrong `--community` needs a database to ask its
## question, but the line it prints does not. A single line naming the session
## and the community is the difference between a refused argument and the
## `events:0` a silent `ingestSession` return used to produce.

suite "ratingingest community guard":
  test "the message names both the session and the community":
    check absentSessionMessage("0f8fad5b-d9cb-469f-a165-70867728950e",
      "waverly") ==
      "no session 0f8fad5b-d9cb-469f-a165-70867728950e in community waverly"

  test "the message stays on one line":
    let message = absentSessionMessage("abc", "ticker-club")
    check '\n' notin message
    check '\r' notin message