import std/[json, options, sets, unittest]
import api/src/routes_gen
import ../domain/roles

const matrixPath = "testdata/authz/matrix.yaml"

proc loadMatrix(): JsonNode =
  let document = parseFile(matrixPath)
  if not document.hasKey("operations"):
    raise newException(ValueError, matrixPath & ": missing operations")
  document["operations"]

proc principal(session = true, role = none(Role), owner = false): Principal =
  Principal(hasSession: session, role: role, isPlatformOwner: owner)

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
