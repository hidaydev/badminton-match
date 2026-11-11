import std/[strutils, unittest]
import ../tenancy

## The rule half of DB-16 option (c): one community per production database
## until RLS ships. The query half is covered by the API integration suite,
## because it needs a database with two communities in it.

suite "one community per production database":
  test "an empty or single-community database is allowed in production":
    check singleCommunityViolation(0, "prod") == ""
    check singleCommunityViolation(1, "prod") == ""

  test "a second community is refused in production":
    let violation = singleCommunityViolation(2, "prod")
    check violation.len > 0
    check violation.contains("2 communities")
    check violation.contains("ADR-018")
    check violation.contains("rls-tenancy-options.md")

  test "development and test databases may hold many communities":
    check singleCommunityViolation(34, "dev") == ""
    check singleCommunityViolation(34, "test") == ""
    check singleCommunityViolation(34, "") == ""
