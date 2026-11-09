import std/[json, options, unittest]
import ../schedule

## Unit tests for the request parsing side of the schedule. `putSchedule` needs
## a database, so the rules that decide whether a payload may reach it live here
## (SQ-15): a duplicate slot and a player standing twice are refused before any
## round trip, and a mutation of either check has to turn this red.

proc game(round, court: int, first = "", second = "",
          firstB = "", secondB = ""): JsonNode =
  ## One game object in the contract's shape; empty ids stay absent so a pair
  ## game does not have to name an empty second slot.
  var sideA = newJArray()
  if first.len > 0: sideA.add(%first)
  if second.len > 0: sideA.add(%second)
  var sideB = newJArray()
  if firstB.len > 0: sideB.add(%firstB)
  if secondB.len > 0: sideB.add(%secondB)
  %*{"round": round, "court": court, "sideA": sideA, "sideB": sideB}

suite "schedule payload":
  test "distinct slots parse in order":
    let games = parseSchedule(%*{"games": [
      game(0, 0, "a", "b", "c", "d"),
      game(0, 1, "a", "c", "b", "d"),
    ]})
    check games.len == 2
    check games[0].round == 0
    check games[0].court == 0
    check games[1].court == 1
    check games[1].sideA.first == "a"
    check games[1].sideB.second == "d"

  test "one slot cannot appear twice":
    expect ValueError:
      discard parseSchedule(%*{"games": [
        game(1, 2, "a", "b"),
        game(1, 2, "c", "d"),
      ]})

  test "a player cannot stand twice in one game":
    expect ValueError:
      discard parseSchedule(%*{"games": [game(0, 0, "a", "b", "b", "c")]})

  test "a side takes at most two players":
    expect ValueError:
      discard parseSchedule(%*{"games": [
        %*{"round": 0, "court": 0, "sideA": ["a", "b", "c"]},
      ]})

  test "a negative slot is refused":
    expect ValueError:
      discard parseSchedule(%*{"games": [game(-1, 0, "a", "b")]})

  test "a zero slot is a real slot":
    let games = parseSchedule(%*{"games": [game(0, 0, "a", "b")]})
    check games.len == 1

  test "the contract key is round and court":
    check parseGameKey("3-4") == some((3, 4))
    check parseGameKey("3") == none((int, int))
    check parseGameKey("3-x") == none((int, int))
    check parseGameKey("") == none((int, int))
