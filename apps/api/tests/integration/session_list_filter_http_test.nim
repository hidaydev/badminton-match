## FE-19: the home card asks the server for the newest draft instead of
## scanning the first page of every session. The route needs a status filter
## for that, and a draft past the first page has to be reachable.

import std/[json, unittest]
import db/db
import tests/fixtures
import ../http_support

let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  slug = "session-status"
  adminEmail = "session-status-admin@example.com"

var
  database: Db
  communityId, adminId, draftId: string
  adminCookie: string

const newerSessions = 119

proc bootstrap() =
  database = openDb(dsn(), 1)
  purgeCommunity(database, slug)
  discard database.execUpdate(
    """delete from account.sessions where user_id in
         (select id from platform.user where google_sub like 'session-status-%')""")
  discard database.execUpdate(
    "delete from platform.user where google_sub like 'session-status-%'")

  adminId = newUser(database, "session-status-admin", adminEmail, "Status Admin")
  communityId = newCommunity(database, slug, "Status Club")
  newMember(database, communityId, adminId, "admin")
  adminCookie = cookieFor(database, adminId)

  # Newest first is `session_date desc`, so every finished session is newer
  # than the draft: the draft is the 120th row, past the default page.
  for index in 0 ..< newerSessions:
    let day = 1 + index mod 28
    let month = 1 + index div 28
    discard newSession(database, communityId, "Finished " & $index,
      sessionDate = "2026-" & (if month < 10: "0" else: "") & $month & "-" &
        (if day < 10: "0" else: "") & $day,
      status = "locked", approved = true)
  draftId = newSession(database, communityId, "The 120th draft",
    sessionDate = "2025-12-31", status = "draft")

  startServer(newTestApp(database), port, baseUrl)

bootstrap()

suite "session list status filter":
  test "status=draft with limit=1 returns the draft beyond the first page":
    let response = call(baseUrl, HttpGet,
      "/c/" & slug & "/sessions?status=draft&limit=1", adminCookie)
    checkpoint($response.status & " " & response.body)
    expectStatus(response, 200)
    let body = response.json()
    check body["total"].getInt() == 1
    check body["nextCursor"].getStr().len == 0
    check body["items"].len == 1
    check body["items"][0]["id"].getStr() == draftId
    check body["items"][0]["status"].getStr() == "draft"

  test "the unfiltered first page does not hold the draft":
    let response = call(baseUrl, HttpGet,
      "/c/" & slug & "/sessions?limit=1", adminCookie)
    expectStatus(response, 200)
    let body = response.json()
    check body["total"].getInt() == newerSessions + 1
    check body["items"][0]["id"].getStr() != draftId

  test "an unknown status narrows nothing instead of failing the read":
    let response = call(baseUrl, HttpGet,
      "/c/" & slug & "/sessions?status=finished", adminCookie)
    expectStatus(response, 200)
    check response.json()["total"].getInt() == newerSessions + 1
