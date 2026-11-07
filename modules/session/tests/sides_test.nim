## The one table of which game counts, shared by standings, rating and badges.

import std/[sets, unittest]
import ../sides

proc ids(values: varargs[string]): HashSet[string] =
  for value in values:
    result.incl(value)

suite "game sides":
  test "a full game counts for both sides":
    let game = sides("a1", "a2", "b1", "b2", ids(), ids())
    check game.presentA == @["a1", "a2"]
    check game.presentB == @["b1", "b2"]
    check game.eligibleA == @["a1", "a2"]
    check game.eligibleB == @["b1", "b2"]
    check game.counts

  test "one absent side voids the game":
    let game = sides("a1", "a2", "b1", "b2", ids("b1", "b2"), ids())
    check game.presentA == @["a1", "a2"]
    check game.presentB.len == 0
    check not game.counts

  test "both sides all-skip voids the game":
    let game = sides("a1", "a2", "b1", "b2", ids(),
      ids("a1", "a2", "b1", "b2"))
    check game.eligibleA.len == 0
    check game.eligibleB.len == 0
    check not game.counts

  test "one side all-skip still counts for the other":
    let game = sides("a1", "a2", "b1", "b2", ids(), ids("a1", "a2"))
    check game.eligibleA.len == 0
    check game.eligibleB == @["b1", "b2"]
    check game.counts

  test "a skipped player is not eligible but is present":
    let game = sides("a1", "a2", "b1", "b2", ids(), ids("a1"))
    check game.presentA == @["a1", "a2"]
    check game.eligibleA == @["a2"]
    check game.counts

  test "an empty slot is not a player":
    let game = sides("a1", "", "b1", "", ids(), ids())
    check game.presentA == @["a1"]
    check game.presentB == @["b1"]
    check game.counts

  test "a pair game with one empty side does not count":
    let game = sides("a1", "", "", "", ids(), ids())
    check game.presentA == @["a1"]
    check game.presentB.len == 0
    check not game.counts