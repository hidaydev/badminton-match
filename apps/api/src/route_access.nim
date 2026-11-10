## The access class of a request, decided from its verb and path alone.
##
## `route()` gates every community route through `operationAccess`, and
## `modules/account/tests/authz_matrix_test.nim` walks the contract's
## `routes_gen` against the same function, so the dispatched class and
## `testdata/authz/matrix.yaml` cannot drift apart without a failing test.
## `operationKnown` exposes whether a rule matched at all, which is what
## `./task contract-keys` gates: a contract route the table never learned must
## not inherit the fallback class silently.
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

type
  Classified = tuple[access: Access, known: bool]
    ## `known` is false only when no rule matched the shape. The old default
    ## granted `readAccess` to anything, so a contract route the table never
    ## learned looked like a deliberate member route. `./task contract-keys`
    ## now fails on that for every operation the spec declares.

proc classify(verb, path: string): Classified =
  ## One row per operation shape. Contract verbs get the class the matrix
  ## declares; an unknown verb on a known shape keeps the shape's default, so
  ## a request that ends in 405 still reaches the same gate it used to.
  let parts = path.split('/')
  if path in ["/healthz", "/readyz", "/version", "/directory",
              "/auth/start", "/auth/callback"]:
    return (publicAccess(), true)
  if path in ["/auth/logout", "/auth/me", "/auth/sessions"]:
    return (readAccess(), true)
  if path == "/communities":
    if verb == "POST":
      return (ownerAccess(), true)
    return (readAccess(), true)
  if parts.len >= 3 and parts[1] == "ws":
    # /ws/c/{slug}/sessions/{id} needs a membership; /ws/share/{code} is the
    # public door of a share link.
    if parts[2] == "share":
      return (publicAccess(), true)
    return (readAccess(), true)
  if parts.len >= 3 and parts[1] == "s":
    return (publicAccess(), true)
  if parts.len == 4 and parts[1] == "invites":
    return (readAccess(), true)
  if parts.len >= 4 and parts[1] == "c":
    case parts[3]
    of "players":
      if verb == "DELETE" and parts.len == 5:
        return (adminAccess(), true)
      if verb == "POST" and parts.len == 6 and parts[5] == "merge":
        return (adminAccess(), true)
      if verb == "PATCH" and parts.len == 7 and parts[5] == "claims":
        return (adminAccess(), true)
      # Nested reads (claims, achievements, stats) and the plain reads are
      # member; every other write is host/admin.
      if parts.len >= 6 or verb == "GET":
        return (readAccess(), true)
      return (writeAccess(), true)
    of "sessions":
      if parts.len == 6:
        case parts[5]
        of "standings", "ws-ticket":
          return (readAccess(), true)
        of "rating":
          if verb in ["POST", "DELETE"]:
            return (adminAccess(), true)
          return (writeAccess(), true)
        of "games":
          # Reading one game is a member route; scoring it is not.
          if verb == "GET":
            return (readAccess(), true)
          return (writeAccess(), true)
        else:
          return (writeAccess(), true)
      if parts.len == 7 and parts[5] == "games" and verb == "GET":
        return (readAccess(), true)
      if parts.len >= 6:
        return (writeAccess(), true)
      if verb == "GET":
        return (readAccess(), true)
      return (writeAccess(), true)
    of "tournaments":
      if parts.len == 6 and parts[5] == "rating" and verb in ["POST", "DELETE"]:
        return (adminAccess(), true)
      if verb == "GET":
        return (readAccess(), true)
      return (writeAccess(), true)
    of "ratings", "rating-sources":
      return (adminAccess(), true)
    of "members":
      if parts.len == 4 and verb == "GET":
        return (readAccess(), true)
      return (adminAccess(), true)
    of "join-requests":
      # Only the exact create shape is the anonymous door; the badge decides
      # the rest, and an extra segment must not inherit the public class.
      if verb == "POST" and parts.len == 4:
        return (publicAccess(), true)
      return (adminAccess(), true)
    of "claims", "invites":
      return (adminAccess(), true)
    of "config":
      # The effective config is what a member's screen reads (export sizes,
      # page limits); it is the only member read in this family.
      if verb == "GET":
        return (readAccess(), true)
      return (adminAccess(), true)
    of "settings":
      if verb == "GET":
        return (readAccess(), true)
      return (adminAccess(), true)
    of "rankings":
      return (readAccess(), true)
    else:
      discard
  # No rule matched: the shape is unknown to this table. The class stays the
  # historical default so the request path is unchanged, but `known` is what
  # the contract gate reads.
  (readAccess(), false)

proc operationAccess*(verb, path: string): Access =
  classify(verb, path).access

proc operationKnown*(verb, path: string): bool =
  ## True when an explicit rule classified the shape, false for the fallback.
  classify(verb, path).known