## One rule for which game counts, and one reading of its four slots.
##
## This module is pure: no database, no clock. Standings, the rating ingest, the
## board projection and the achievement backfill all decide the same thing — a
## game counts only when both sides still have a present player, and a side that
## was entirely skipped still leaves the game alive for the other one — so the
## decision lives here instead of in four transcriptions.

import std/sets

## The four game slots as text, with an empty slot as the empty string. Four
## queries used to spell this projection out; one migration touching
## `session.games` would have needed four edits. The alias names are part of the
## contract with `sides()` (SQ-16).
const gameSideColumns* =
  """coalesce(side_a1::text, '') as side_a1,
              coalesce(side_a2::text, '') as side_a2,
              coalesce(side_b1::text, '') as side_b1,
              coalesce(side_b2::text, '') as side_b2"""

type
  GameSides* = object
    ## The four slots split into sides. `present` drops empty slots and absent
    ## players; `eligible` also drops the players skipped out of this game.
    presentA*, presentB*: seq[string]
    eligibleA*, eligibleB*: seq[string]

proc sideOf(a1, a2: string, absent: HashSet[string]): seq[string] =
  for playerId in [a1, a2]:
    if playerId.len > 0 and playerId notin absent:
      result.add(playerId)

proc eligible(players: seq[string], skipped: HashSet[string]): seq[string] =
  for playerId in players:
    if playerId notin skipped:
      result.add(playerId)

proc sides*(a1, a2, b1, b2: string, absent,
            skipped: HashSet[string]): GameSides =
  ## Splits one game's four slots. An empty slot is a missing player, not an
  ## id: pair games leave one of the two slots unset.
  result.presentA = sideOf(a1, a2, absent)
  result.presentB = sideOf(b1, b2, absent)
  result.eligibleA = eligible(result.presentA, skipped)
  result.eligibleB = eligible(result.presentB, skipped)

proc counts*(s: GameSides): bool =
  ## Absence removes the game: a side with no present player has no one to
  ## tally. A per-game skip only removes those players from the game, so the
  ## opposing side still gets the result unless both sides end up empty.
  s.presentA.len > 0 and s.presentB.len > 0 and
    (s.eligibleA.len > 0 or s.eligibleB.len > 0)