import std/unittest
import ../src/quota_route

suite "quota route labels":
  test "a contract path uses its template":
    check quotaRoute("/c/majadu/sessions/42") == "/c/{slug}/sessions/{id}"
    check quotaRoute("/c/majadu/sessions") == "/c/{slug}/sessions"
    check quotaRoute("/healthz") == "/healthz"

  test "unknown paths share one label":
    for index in 0 ..< 2000:
      check quotaRoute("/zzz" & $index) == UnmatchedRoute
    check quotaRoute("/c/majadu/zzz123") == UnmatchedRoute

  test "missing and extra segments do not match":
    check quotaRoute("/c/majadu/sessions/42/extra") == UnmatchedRoute
    check quotaRoute("/c/majadu/sessions/42/games/1/extra") == UnmatchedRoute

  test "the ops ping keeps its own bucket":
    check quotaRoute("/ops/ping") == "/ops/ping"

suite "contract shape lookup":
  test "a declared shape is known, whatever its verb":
    # SQ-05: the dispatcher asks this to answer 405 for a known shape asked
    # with the wrong verb, so the sub-path list has one home.
    for path in ["/c/majadu/sessions/42", "/c/majadu/sessions", "/healthz",
                 "/c/majadu/players/7/claims/9", "/s/abc/rankings"]:
      check contractShapeKnown(path)

  test "an invented shape and an over-long path are not known":
    for path in ["/zzz", "/be19-no-route", "/c/majadu/zzz123",
                 "/c/majadu/sessions/42/extra", "/s", "/c/majadu/players/7/zzz"]:
      check not contractShapeKnown(path)
