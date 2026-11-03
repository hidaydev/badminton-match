import std/options
import account/domain/roles
import community_context

type
  Gate* = enum
    gAllowed = "allow"
    gUnauthenticated = "unauthenticated"
    gForbidden = "forbidden"
    gNotFound = "not found"

  Actor* = object
    ## Who is calling. The session token is kept so logout and revoke can act on
    ## the exact row that authenticated this request.
    userId*: string
    isPlatformOwner*: bool
    sessionToken*: string

proc gate*(access: Access, actor: Option[Actor],
           community: Option[CommunityContext]): Gate =
  ## One decision point for every community route. Order matters: a missing
  ## session is 401 before anything else, then membership (404) so a foreign
  ## community looks absent, then the role check (403).
  if access.isPublic:
    return gAllowed
  if actor.isNone:
    return gUnauthenticated
  if access.ownerOnly:
    # Management actions belong to the platform owner and never depend on a
    # community membership.
    return if actor.get.isPlatformOwner: gAllowed else: gForbidden
  if community.isNone:
    return gNotFound
  let principal = Principal(
    hasSession: true,
    role: some(community.get.role),
    isPlatformOwner: actor.get.isPlatformOwner,
  )
  if access.can(principal):
    gAllowed
  else:
    gForbidden

proc statusFor*(gate: Gate): int =
  case gate
  of gAllowed: 200
  of gUnauthenticated: 401
  of gForbidden: 403
  of gNotFound: 404

proc codeFor*(gate: Gate): string =
  case gate
  of gAllowed: "OK"
  of gUnauthenticated: "UNAUTHENTICATED"
  of gForbidden: "FORBIDDEN"
  of gNotFound: "NOT_FOUND"
