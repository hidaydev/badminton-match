## The two rules `createShare` reads before it mints a code, held without a
## database: which statuses a link may serve, and how long a draft's link lives.

import std/unittest
import ../store

suite "share gate":
  test "a draft is shareable, a finished season is not":
    ## SEC-09 as amended 2026-11-21: the host hands the link out on the day of
    ## play, so a draft must answer. `archived` means the season is over, and a
    ## code minted earlier must stop publishing it.
    check shareable("draft")
    check shareable("locked")
    check shareable("published")
    check shareable("completed")
    check not shareable("archived")

  test "a draft's link is capped at 48 hours, an approved one keeps the TTL":
    check linkTtlDays("draft", 30) == 2
    check linkTtlDays("draft", 1) == 1
    check linkTtlDays("locked", 30) == 30
    check linkTtlDays("published", 30) == 30
    # The cap is a ceiling, never a floor: a community that lowered its own TTL
    # keeps the number it chose.
    check linkTtlDays("draft", 7) == 2
