## REL-BE-09: deleting a session with N share links used to run N ticket deletes,
## each on its own pooled connection, after the delete had already committed. The
## ids are now collected inside the transaction and the tickets go in one
## statement on that same connection. These cases pin the shape that makes the
## round-trip count independent of N; the row counts need a database and live in
## the integration set.

import std/[os, strutils, unittest]
import platform/ws_ticket
import db/db

let ticketSource = readFile(currentSourcePath().parentDir / "../ws_ticket.nim")
let appSource = readFile(currentSourcePath().parentDir /
  "../../../apps/api/src/app.nim")

suite "batch share-ticket revoke":
  test "one statement covers the whole set":
    check revokeSharesSql.count("delete from") == 1
    # One array parameter, not a per-id placeholder: the statement text does not
    # grow with the number of links.
    check revokeSharesSql.contains("any($1::uuid[])")
    check revokeSharesSql.count("$") == 1

  test "an empty set costs no round trip at all":
    ## A session with no live link must not open a connection to delete nothing.
    # `revokeShares` returns before touching the pool; a `Db` with no connection
    # proves it, because any checkout would raise here.
    check revokeShares(Db(), @[]) == 0

  test "the id array survives escaping":
    ## `textArray` quotes each element, so the array literal is one parameter
    ## however many ids it carries.
    let literal = textArray(@["a", "b"])
    check literal == """{"a","b"}"""

  test "the delete collects the ids on its own transaction":
    # The ids are read with the tx's own facade (`boundTo`), the tickets are
    # deleted on that same facade, and only the socket close waits for the
    # commit. A second pooled checkout in this route is what the row removed.
    check appSource.contains("shareStore.liveLinks(database().boundTo(conn)")
    check appSource.contains("wsTicket.revokeShares(database().boundTo(conn)")

  test "no per-link delete is left on the pool":
    ## The old shape: one `hub.revokeShare` per link, each a pooled checkout.
    check not appSource.contains("""for linkId in links:
    application.hub.revokeShare(linkId)""")
