## The access class of a request, decided from its verb and path alone.
##
## `route()` gates every community route through `operationAccess`, and
## `modules/account/tests/authz_matrix_test.nim` walks the contract's
## `routes_gen` against the same function, so the dispatched class and
## `testdata/authz/matrix.yaml` cannot drift apart without a failing test.
## Nothing here touches the database or the request: it is a pure table.
import std/strutils
import account/domain/roles

proc publicAccess*(): Access =
  Access(isPublic: true)

proc readAccess*(): Access =
  ## Any membership role can read; the community context already proved
  ## membership, and roles decide writes only.
  Access(isSession: true)

proc writeAccess*(): Access =
  Access(isSession: true, roles: @[rHost, rAdmin])

proc adminAccess*(): Access =
  Access(isSession: true, roles: @[rAdmin])

proc ownerAccess*(): Access =
  ## Platform-owner management: no community membership is involved.
  Access(isSession: true, ownerOnly: true)

proc operationAccess*(verb, path: string): Access =
  ## One row per operation shape. Contract verbs get the class the matrix
  ## declares; an unknown verb on a known shape keeps the shape's default, so
  ## a request that ends in 405 still reaches the same gate it used to.
  let parts = path.split('/')
  if path in ["/healthz", "/readyz", "/version", "/directory",
              "/auth/start", "/auth/callback"]:
    return publicAccess()
  if path in ["/auth/logout", "/auth/me", "/auth/sessions"]:
    return readAccess()
  if path == "/communities":
    return if verb == "POST": ownerAccess() else: readAccess()
  if parts.len >= 3 and parts[1] == "ws":
    # /ws/c/{slug}/sessions/{id} needs a membership; /ws/share/{code} is the
    # public door of a share link.
    return if parts[2] == "share": publicAccess() else: readAccess()
  if parts.len >= 3 and parts[1] == "s":
    return publicAccess()
  if parts.len == 4 and parts[1] == "invites":
    return readAccess()
  if parts.len >= 4 and parts[1] == "c":
    case parts[3]
    of "players":
      if verb == "DELETE" and parts.len == 5:
        return adminAccess()
      if verb == "POST" and parts.len == 6 and parts[5] == "merge":
        return adminAccess()
      if verb == "PATCH" and parts.len == 7 and parts[5] == "claims":
        return adminAccess()
      # Nested reads (claims, achievements, stats) and the plain reads are
      # member; every other write is host/admin.
      if parts.len >= 6 or verb == "GET":
        return readAccess()
      return writeAccess()
    of "sessions":
      if parts.len == 6:
        case parts[5]
        of "standings", "ws-ticket":
          return readAccess()
        of "rating":
          if verb in ["POST", "DELETE"]:
            return adminAccess()
          return writeAccess()
        of "games":
          # Reading one game is a member route; scoring it is not.
          return if verb == "GET": readAccess() else: writeAccess()
        else:
          return writeAccess()
      if parts.len == 7 and parts[5] == "games" and verb == "GET":
        return readAccess()
      if parts.len >= 6:
        return writeAccess()
      return if verb == "GET": readAccess() else: writeAccess()
    of "tournaments":
      if parts.len == 6 and parts[5] == "rating" and verb in ["POST", "DELETE"]:
        return adminAccess()
      return if verb == "GET": readAccess() else: writeAccess()
    of "ratings", "rating-sources":
      return adminAccess()
    of "members":
      if parts.len == 4 and verb == "GET":
        return readAccess()
      return adminAccess()
    of "join-requests":
      # Only the exact create shape is the anonymous door; the badge decides
      # the rest, and an extra segment must not inherit the public class.
      return if verb == "POST" and parts.len == 4: publicAccess()
             else: adminAccess()
    of "claims", "invites":
      return adminAccess()
    of "config":
      # The effective config is what a member's screen reads (export sizes,
      # page limits); it is the only member read in this family.
      return if verb == "GET": readAccess() else: adminAccess()
    of "settings":
      return if verb == "GET": readAccess() else: adminAccess()
    of "rankings":
      return readAccess()
    else:
      discard
  readAccess()