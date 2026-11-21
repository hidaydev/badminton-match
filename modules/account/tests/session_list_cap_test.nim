## REL-BE-10: `/auth/sessions` returned every live session row for the user with
## no bound. The route now passes the configured page cap
## (`api.page_size_max`), the same key `pageParams` clamps every other list route
## with. The cap's effect on rows needs a database and lives in the integration
## set; these cases pin that the bound exists and where its number comes from.

import std/[os, strutils, unittest]
import platform/config/registry

let storeSource = readFile(currentSourcePath().parentDir /
  "../infrastructure/session_store.nim")
let appSource = readFile(currentSourcePath().parentDir /
  "../../../apps/api/src/app.nim")

suite "bounded auth session list":
  test "the query is bounded and the limit is a parameter":
    check storeSource.contains("order by last_seen_at desc")
    check storeSource.contains("limit $3")
    # The bound travels as a parameter, so the same statement serves any cap the
    # registry holds instead of a second prepared shape per value.
    check storeSource.contains("intParam(limit.int64)")

  test "the cap is the key the other list routes already use":
    ## No new config key: the route reads `api.page_size_max`, the ceiling
    ## `pageParams` applies to every paged collection.
    check $keyApiPageSizeMax == "api.page_size_max"
    check appSource.contains("snapshot.intValue(%*{}, keyApiPageSizeMax)")

  test "the route passes that cap to the store":
    check appSource.contains(
      "listSessions(database(), user.get.id, user.get.token, cap)")

  test "the newest sessions win when the cap bites":
    # The order is what makes a truncated page the useful one: the row the person
    # just used is at the top.
    check storeSource.contains("order by last_seen_at desc")
