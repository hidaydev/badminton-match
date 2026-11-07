import std/[json, options, sets, strutils, unittest]
import api/src/routes_gen
import api/src/route_access
import ../domain/roles

const matrixPath = "testdata/authz/matrix.yaml"

proc loadMatrix(): JsonNode =
  let document = parseFile(matrixPath)
  if not document.hasKey("operations"):
    raise newException(ValueError, matrixPath & ": missing operations")
  document["operations"]

proc principal(session = true, role = none(Role), owner = false): Principal =
  Principal(hasSession: session, role: role, isPlatformOwner: owner)

const pathParams = ["slug", "id", "gameKey", "playerId", "claimId", "matchId",
                    "userId", "code", "token"]

proc concrete(path: string): string =
  ## One fixed value per parameter: the classifier reads the shape of the path,
  ## never the value, so any concrete segment answers the same question.
  result = path
  for name in pathParams:
    result = result.replace("{" & name & "}", "x")

proc impostors(operations: JsonNode): seq[string] =
  ## Every operation whose dispatched class disagrees with its matrix row.
  for route in routes:
    let dispatched = operationAccess(route.httpMethod, concrete(route.path))
    let declared = parseAccess(operations[route.operationId])
    if dispatched.describe() != declared.describe():
      result.add(route.operationId)

suite "authorization matrix":
  test "every contract operation has a row":
    let operations = loadMatrix()
    var missing: seq[string] = @[]
    for route in routes:
      if not operations.hasKey(route.operationId):
        missing.add(route.operationId)
    check missing.len == 0

  test "the matrix has no row for an unknown operation":
    let operations = loadMatrix()
    var known = initHashSet[string]()
    for route in routes:
      known.incl(route.operationId)
    for operationId in operations.keys:
      check operationId in known

  test "public routes need no session":
    let operations = loadMatrix()
    for route in routes:
      let access = parseAccess(operations[route.operationId])
      if access.isPublic:
        check access.can(principal(session = false))

  test "session routes refuse an anonymous caller":
    let operations = loadMatrix()
    for route in routes:
      let access = parseAccess(operations[route.operationId])
      if access.isSession:
        check not access.can(principal(session = false))

  test "hosts cannot administer the community":
    let operations = loadMatrix()
    let createInvite = parseAccess(operations["createInvite"])
    check createInvite.can(principal(role = some(rAdmin)))
    check not createInvite.can(principal(role = some(rHost)))
    check not createInvite.can(principal(role = some(rMember)))
    check not createInvite.can(principal(role = none(Role), owner = true))

  test "members and hosts can read, only hosts write sessions":
    let operations = loadMatrix()
    check parseAccess(operations["listSessions"]).can(principal(role = some(rMember)))
    check parseAccess(operations["listSessions"]).can(principal(role = some(rHost)))
    check not parseAccess(operations["createSession"]).can(principal(role = some(rMember)))
    check parseAccess(operations["createSession"]).can(principal(role = some(rHost)))

  test "platform owner is required for community creation":
    let operations = loadMatrix()
    let create = parseAccess(operations["createCommunity"])
    check create.can(principal(owner = true))
    check not create.can(principal(role = some(rAdmin)))

  test "a platform owner with a member membership keeps member rights":
    let operations = loadMatrix()
    let write = parseAccess(operations["createSession"])
    check not write.can(principal(role = some(rMember), owner = true))
    let read = parseAccess(operations["listSessions"])
    check read.can(principal(role = some(rMember), owner = true))

  test "a user without a membership has no community role":
    let operations = loadMatrix()
    let read = parseAccess(operations["listSessions"])
    check not read.can(principal(role = none(Role)))

  test "matrix rows are parseable and complete":
    let operations = loadMatrix()
    for operationId in operations.keys:
      let access = parseAccess(operations[operationId])
      check access.describe().len > 0

  test "the public doors are public":
    # Login starts without a session, the directory is for outsiders, and a
    # join request is accepted from someone who is not signed in yet.
    let operations = loadMatrix()
    for operationId in ["postAuthStart", "getDirectory", "createJoinRequest"]:
      check parseAccess(operations[operationId]).isPublic

  test "player administration is admin-only, not host":
    # Hosts run the session; deleting a player, merging two or deciding a claim
    # rewrites history, and the dispatch gates those for admin for exactly that.
    let operations = loadMatrix()
    for operationId in ["deletePlayer", "postPlayerMerge", "patchPlayerClaim",
                        "listRatingSources"]:
      let access = parseAccess(operations[operationId])
      check access.can(principal(role = some(rAdmin)))
      check not access.can(principal(role = some(rHost)))
      check not access.can(principal(role = some(rMember)))

  test "the dispatch grants each operation the class the matrix declares":
    # The matrix is the specification; route() gates through operationAccess,
    # so this compares the code with the document instead of the document with
    # itself. No operation may disagree: a row that says `session` where the
    # handler needs admin is a member route that answers 403, not a doc typo.
    check impostors(loadMatrix()).len == 0

  test "the dispatch guard fails when one operation changes class":
    # Proof by changing the matrix in memory, never the file: one read turned
    # into a write and one write turned into a read must both be reported.
    var flipped = loadMatrix()
    flipped["getSessionGame"] =
      %*{"auth": "session", "roles": ["host", "admin"]}
    flipped["createSession"] = %*{"auth": "session"}
    let found = impostors(flipped)
    check "getSessionGame" in found
    check "createSession" in found
    check found.len == impostors(loadMatrix()).len + 2

  test "only the exact create shape is the anonymous join-request door":
    # The dispatch reaches the family block for any length >= 4; a public class
    # there would skip the membership check and the handler would read a
    # context that was never built.
    check operationAccess("POST", "/c/x/join-requests").isPublic
    for path in ["/c/x/join-requests/abc", "/c/x/join-requests/abc/extra"]:
      let access = operationAccess("POST", path)
      check not access.isPublic
      check access.can(principal(role = some(rAdmin)))
      check not access.can(principal(role = some(rMember)))

  test "a member reads a game and only a host scores it":
    let read = operationAccess("GET", "/c/x/sessions/s/games/g")
    check read.can(principal(role = some(rMember)))
    check read.can(principal(role = some(rHost)))
    let write = operationAccess("PATCH", "/c/x/sessions/s/games/g")
    check not write.can(principal(role = some(rMember)))
    check write.can(principal(role = some(rHost)))
