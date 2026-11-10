## SEC-10: the case that matters is the silent one. A contract route the access
## table never learned used to inherit `readAccess()`, and a matrix row that said
## "session" agreed with the fallback, so every gate stayed green. These cases
## feed the checker a classifier, so they can prove that outcome without editing
## the production table.

import std/[json, strutils, unittest]

import ../main as contractKeys

import api/src/routes_gen
import api/src/route_access

proc row(auth: string, roles: seq[string] = @[]): JsonNode =
  result = %*{"auth": auth}
  if roles.len > 0:
    var list = newJArray()
    for role in roles:
      list.add(%role)
    result["roles"] = list

proc route(operationId, httpMethod, path: string): RouteSpec =
  RouteSpec(operationId: operationId, httpMethod: httpMethod, path: path)

proc alwaysKnown(verb, path: string): bool = true

suite "contract keys":
  test "the committed contract and matrix pass":
    # The real table, not a stub: a rule deleted from route_access.nim breaks
    # this case as well as the gate.
    check contractKeys.problems(routes, contractKeys.loadMatrix(),
      operationAccess, operationKnown).len == 0

  test "a declared operation without a matrix row is named":
    let declared = %*{"getHealthz": row("public")}
    let found = contractKeys.problems(
      [route("getHealthz", "GET", "/healthz"),
       route("patchPlayer", "PATCH", "/c/{slug}/players/{playerId}")],
      declared, operationAccess, alwaysKnown)
    check found.len == 1
    check found[0].contains("patchPlayer")
    check found[0].contains("no row in testdata/authz/matrix.yaml")

  test "a shape the access table has no rule for is named":
    let declared = %*{"listPlayers": row("session")}
    # `known` answers false for this shape, which is exactly the fallback the
    # production table would have taken before this gate existed.
    let found = contractKeys.problems(
      [route("listPlayers", "GET", "/c/{slug}/players")], declared,
      operationAccess, proc(verb, path: string): bool = false)
    check found.len == 1
    check found[0].contains("listPlayers")
    check found[0].contains("no explicit rule in apps/api/src/route_access.nim")

  test "a class the dispatch disagrees with is reported with both classes":
    let declared = %*{"createSession": row("session")}
    let found = contractKeys.problems(
      [route("createSession", "POST", "/c/{slug}/sessions")], declared,
      operationAccess, alwaysKnown)
    check found.len == 1
    check found[0].contains("createSession")
    check found[0].contains("the dispatch grants session:host,admin")
    check found[0].contains("declares session")

  test "a matrix row for an operation the contract does not declare is reported":
    let declared = %*{
      "getHealthz": row("public"),
      "ghostOperation": row("session", @["admin"])}
    let found = contractKeys.problems(
      [route("getHealthz", "GET", "/healthz")], declared, operationAccess,
      alwaysKnown)
    check found.len == 1
    check found[0].contains("ghostOperation")
    check found[0].contains("operation the contract does not declare")

  test "an unreadable matrix row is reported against its operation":
    let declared = %*{"getHealthz": %*{"roles": ["admin"]}}
    let found = contractKeys.problems(
      [route("getHealthz", "GET", "/healthz")], declared, operationAccess,
      alwaysKnown)
    check found.len == 1
    check found[0].contains("getHealthz")
    check found[0].contains("row is unreadable")
