## The three definitions every reader of a session has to agree on.

import std/[options, strutils, unittest]
import ../lifecycle

const approvedAt = some("2026-11-03T20:00:00")

suite "session lifecycle":
  test "only a draft is editable":
    check isEditable("draft")
    check not isEditable("locked")
    check not isEditable("published")
    check not isEditable("")

  test "a rated session carries both an approval stamp and an approved status":
    check isRated(approvedAt, "locked")
    check not isRated(none(string), "locked")
    check not isRated(approvedAt, "draft")
    check not isRated(none(string), "draft")

  test "every approved status is in the SQL list and rated":
    for status in ["locked", "published", "completed", "archived"]:
      let quoted = "'" & status & "'"
      check quoted in approvedStatuses
      check isRated(approvedAt, status)