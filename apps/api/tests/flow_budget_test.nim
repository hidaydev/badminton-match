## QAE-05: the per-address cap on pending OIDC flows. The budget is process
## memory because the flow row carries no address; these cases pin the three
## ways a slot is freed (the callback, expiry, the global ceiling) and that one
## address cannot spend another address's budget.

import std/unittest
import ../src/flow_budget

suite "pending auth flow budget":
  test "an address may hold the cap and not one more":
    let budget = newFlowBudget()
    for index in 0 ..< 4:
      check budget.admit("state-" & $index, "192.0.2.1", 100.0, 0.0, 4) == 0
    check budget.pendingFor("192.0.2.1", 0.0) == 4
    let wait = budget.admit("state-4", "192.0.2.1", 100.0, 0.0, 4)
    check wait > 0
    check budget.pendingFor("192.0.2.1", 0.0) == 4

  test "the retry names the moment a slot comes back":
    let budget = newFlowBudget()
    check budget.admit("short", "192.0.2.2", 10.0, 0.0, 1) == 0
    check budget.admit("long", "192.0.2.2", 50.0, 0.0, 2) == 0
    # The earliest expiry, not the last one, is the next slot.
    check budget.admit("refused", "192.0.2.2", 60.0, 0.0, 2) == 11

  test "a consumed flow frees its slot":
    let budget = newFlowBudget()
    check budget.admit("one", "192.0.2.3", 100.0, 0.0, 1) == 0
    check budget.admit("two", "192.0.2.3", 100.0, 0.0, 1) > 0
    budget.release("one")
    check budget.pendingFor("192.0.2.3", 0.0) == 0
    check budget.admit("three", "192.0.2.3", 100.0, 0.0, 1) == 0

  test "an expired flow frees its slot without a callback":
    let budget = newFlowBudget()
    check budget.admit("old", "192.0.2.4", 10.0, 0.0, 1) == 0
    check budget.admit("new", "192.0.2.4", 21.0, 11.0, 1) == 0
    check budget.pendingFor("192.0.2.4", 11.0) == 1

  test "one address cannot spend another address's budget":
    let budget = newFlowBudget()
    for index in 0 ..< 3:
      check budget.admit("a-" & $index, "192.0.2.5", 100.0, 0.0, 3) == 0
    check budget.admit("b-0", "192.0.2.6", 100.0, 0.0, 3) == 0
    check budget.pendingFor("192.0.2.6", 0.0) == 1

  test "the table stays bounded when addresses rotate":
    let budget = newFlowBudget()
    check budget.admit("first", "198.51.100.1", 10.0, 0.0, 1) == 0
    for index in 0 ..< maxEntries:
      check budget.admit("rotated-" & $index, "203.0.113." & $index,
        1000.0, 1.0, 1) == 0
    # The entry closest to expiry was evicted to make room, and a new address
    # still gets its slot.
    check budget.pendingFor("198.51.100.1", 1.0) == 0
    check budget.pendingFor("203.0.113." & $(maxEntries - 1), 1.0) == 1

  test "reset forgets every pending flow":
    let budget = newFlowBudget()
    check budget.admit("one", "192.0.2.7", 100.0, 0.0, 1) == 0
    budget.reset()
    check budget.pendingFor("192.0.2.7", 0.0) == 0
