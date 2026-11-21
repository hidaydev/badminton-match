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

  test "a retryable condition is unavailable, not a defect":
    ## REL-BE-04: statement_timeout, admin shutdown and a dropped connection are
    ## conditions to retry, so they answer 503 instead of 500. This pair used to
    ## pin 08006 to 500 and alerted a PostgreSQL restart as a code defect.
    for state in ["57014", "57P01", "08006"]:
      checkpoint(state)
      check statusForSqlState(state) == 503
      check codeForSqlState(state) == "UNAVAILABLE"

  test "everything else stays internal":
    check statusForSqlState("") == 500
    check statusForSqlState("XX000") == 500

  test "a held lock is retryable, not a defect":
    check statusForSqlState("55P03") == 503
    check codeForSqlState("55P03") == "UNAVAILABLE"

  test "one code per status":
    for state in ["23505", "23503", "23001"]:
      checkpoint(state)
      check codeForSqlState(state) == "CONFLICT"
    for state in ["23502", "23514", "54000", "22P02", "22007", "22008"]:
      checkpoint(state)
      check codeForSqlState(state) == "INVALID_INPUT"
    check codeForSqlState("XX000") == "INTERNAL"