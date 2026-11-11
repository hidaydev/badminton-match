## One production database serves one community until RLS ships.
##
## ADR-018 (`docs/decisions.md`) and `docs/db/rls-tenancy-options.md` record the
## decision: no row level security now, and the first release that serves a
## second community from one production database is the release that adds it.
## A written condition is not an enforced one, so this is the enforcement: the
## API refuses to start against a production database that holds more than one
## community. The count lives in the database, so a check in the tree cannot be
## the guard; the boot is the last place that can refuse before serving.
##
## The environment argument is the caller's `MAJADU_ENV`. Development and test
## databases hold many communities by design (a local development database had
## 34 when this was written), so only `prod` is constrained.

import std/[options, strutils]
import db/db

proc communityCount*(db: Db): int =
  ## How many communities this database holds. A database before `bootstrap`
  ## has none, which is not a violation.
  let row = db.queryOne(
    "select count(*)::int as total from platform.community").get
  parseInt(row.get("total"))

proc singleCommunityViolation*(communities: int, environment: string): string =
  ## Why a process must not serve this database, or "" when it may. Kept separate
  ## from the query so the rule is testable without a database, and so the
  ## startup path has one message to raise.
  if environment != "prod":
    return ""
  if communities <= 1:
    return ""
  "this database holds " & $communities & " communities; ADR-018 allows one per " &
    "production database until row level security ships " &
    "(docs/db/rls-tenancy-options.md). Move the second community to its own " &
    "database, or ship RLS and the two-community test first."

proc assertSingleCommunity*(db: Db, environment: string) =
  ## Raises `ValueError` with the reason, which is what the API boot reports and
  ## exits on. A refusal must name the condition and the document, not a count.
  let violation = singleCommunityViolation(communityCount(db), environment)
  if violation.len > 0:
    raise newException(ValueError, violation)
