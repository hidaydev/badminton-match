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

suite "the create route sees the same rule":
  # The route refuses before the insert, so the decision is asked about the
  # count the database would hold afterwards. Both halves come from
  # `singleCommunityViolation`, so the boot guard and the route cannot disagree
  # about which environment allows a second community.
  test "creating the second community in production is refused":
    let refusal = createCommunityRefusal(1, "prod")
    check refusal.len > 0
    check refusal.contains("ADR-018")
    check refusal.contains("rls-tenancy-options.md")
    check refusal.contains("already holds 1")

  test "the first community in production is allowed":
    check createCommunityRefusal(0, "prod") == ""

  test "every non-production environment keeps creating communities":
    check createCommunityRefusal(34, "dev") == ""
    check createCommunityRefusal(34, "test") == ""
    check createCommunityRefusal(34, "") == ""
