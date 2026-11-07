## Session lifecycle: one definition of draft, approved and rated.
##
## This module is pure: no database, no config, no clock. Every write path, the
## rating ledger, the board projection and the achievement backfill ask these
## predicates instead of repeating the status list or the approval test.

import std/[options, sequtils, strutils]

const
  approvedStatuses* = "('locked', 'published', 'completed', 'archived')"
    ## The statuses a session holds after it was approved, in SQL form so a
    ## filter can interpolate the list instead of typing it again.
  # The Nim form, derived from the SQL above, so the two cannot drift.
  approvedStatusList = approvedStatuses
    .strip(chars = {'(', ')'})
    .split("', '")
    .mapIt(it.strip(chars = {'\''}))

proc isEditable*(status: string): bool =
  ## Only a draft still takes edits. Locking approves the session, so a later
  ## change has to unlock first, which also withdraws its rating event.
  status == "draft"

proc isRated*(approvedAt: Option[string], status: string): bool =
  ## A session is rated only when the approval stamp and the status agree.
  ## `setLock` writes both columns together, but nothing enforces that, so a
  ## predicate that reads one column alone can count a row the other disowns.
  approvedAt.isSome and status in approvedStatusList