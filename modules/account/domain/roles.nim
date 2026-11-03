import std/[json, options, sequtils, strutils]

type
  Role* = enum
    rMember = "member"
    rHost = "host"
    rAdmin = "admin"

  Access* = object
    ## One row of `testdata/authz/matrix.yaml`.
    isPublic*: bool
    isSession*: bool
    roles*: seq[Role]
    ownerOnly*: bool

  Principal* = object
    ## A request identity. `role` is none when the user has no membership in the
    ## community being addressed; platform ownership is separate on purpose.
    hasSession*: bool
    role*: Option[Role]
    isPlatformOwner*: bool

proc parseRole*(value: string): Role =
  case value
  of "member": rMember
  of "host": rHost
  of "admin": rAdmin
  else: raise newException(ValueError, "unknown role: " & value)

proc parseAccess*(node: JsonNode): Access =
  if not node.hasKey("auth"):
    raise newException(ValueError, "matrix row needs auth")
  case node["auth"].getStr()
  of "public": result.isPublic = true
  of "session": result.isSession = true
  else: raise newException(ValueError, "auth must be public or session")
  if node.hasKey("roles"):
    for role in node["roles"]:
      result.roles.add(parseRole(role.getStr()))
  if node.hasKey("platformOwner"):
    result.ownerOnly = node["platformOwner"].getBool()

proc can*(access: Access, principal: Principal): bool =
  ## Platform ownership bypasses management routes only: inside a community the
  ## membership role decides, so an owner who joined as `member` stays a member.
  if access.isPublic:
    return true
  if not principal.hasSession:
    return false
  if access.ownerOnly:
    return principal.isPlatformOwner
  if access.roles.len == 0:
    # No role list means "any membership", not "any caller": the community
    # context still has to prove that a membership exists.
    return principal.role.isSome
  if principal.role.isNone:
    return false
  principal.role.get in access.roles

proc describe*(access: Access): string =
  if access.isPublic:
    return "public"
  var parts: seq[string] = @["session"]
  if access.ownerOnly:
    parts.add("platformOwner")
  if access.roles.len > 0:
    parts.add(access.roles.mapIt($it).join(","))
  parts.join(":")
