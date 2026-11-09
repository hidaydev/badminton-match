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
