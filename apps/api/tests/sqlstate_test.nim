import std/unittest
import ../src/app

suite "integrity violation status":
  test "one status per SQLSTATE":
    let table = {
      "23505": 409, "23503": 409, "23001": 409,
      "23502": 400, "23514": 400, "54000": 400,
      "22P02": 400, "22007": 400, "22008": 400,
    }
    for (state, status) in table:
      checkpoint(state)
      check statusForSqlState(state) == status

  test "everything else stays internal":
    check statusForSqlState("") == 500
    check statusForSqlState("08006") == 500

  test "one code per status":
    for state in ["23505", "23503", "23001"]:
      checkpoint(state)
      check codeForSqlState(state) == "CONFLICT"
    for state in ["23502", "23514", "54000", "22P02", "22007", "22008"]:
      checkpoint(state)
      check codeForSqlState(state) == "INVALID_INPUT"
    check codeForSqlState("08006") == "INTERNAL"