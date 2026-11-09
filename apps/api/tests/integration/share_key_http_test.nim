## BE-22: a live row whose key the process does not hold is a key problem, not
## a missing link.
##
## The row stays live while `SHARE_CODE_KEYS` no longer holds its `key_id`, which
## is exactly what a retirement without a rotation leaves behind. Answering 404
## ("the link was never created") sends the operator to issue a new link instead
## of restoring the key, so the request answers 503 and the process counts it.

import std/[json, strutils, unittest]
import db/db
import community/infrastructure/community_store
import share/crypto
import share/store as shareStore
import tests/fixtures
import ../../src/app
import ../../src/server
import ../http_support

const
  port = testPort(18112)
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  slug = "share-key-club"
  hostEmail = "sharekey-host@example.com"
  ## The running process holds key 1 only (`keysJson`). The fixture link is
  ## sealed under key 2, so serving it is a key problem and nothing else.
  twoKeys = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","2":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="}"""

var
  database: Db
  communityId, sessionId, hostCookie, liveCode: string

proc bootstrap() =
  database = openDb(dsn(), 1)
  purgeCommunity(database, slug)
  discard database.execUpdate(
    """delete from platform.idempotency_keys where user_id in
         (select id from platform.user where google_sub like 'sharekey-%')""")
  discard database.execUpdate(
    "delete from platform.user where google_sub like 'sharekey-%'")
  let ownerId = newUser(database, "sharekey-owner", "sharekey-owner@example.com",
    "Owner", owner = true)
  communityId = community_store.create(database, slug, "Share Key Club",
    hostEmail, "Asia/Jakarta", ownerId).communityId
  let hostId = newUser(database, "sharekey-host", hostEmail, "Host")
  newMember(database, communityId, hostId, "host")
  hostCookie = cookieFor(database, hostId)
  sessionId = newSession(database, communityId, "Share Key Session")
  liveCode = shareStore.issue(database, loadKeyring(twoKeys, "2"), communityId,
    sessionId, hostId, 7)
  startServer(newTestApp(database), port, baseUrl)

bootstrap()

suite "share link key problem":
  test "a live link under a missing key answers 503, not 404":
    let response = call(baseUrl, HttpGet, "/s/" & liveCode)
    check response.status == 503
    check parseJson(response.body)["code"].getStr() == "UNAVAILABLE"

  test "the key problem line names the link and never the code":
    # The same builder the 503 writes; asserting it directly keeps the suite
    # off the worker thread's stdout.
    let log = shareKeyProblemLine("0193f0e2-0000-7000-8000-000000000010",
      "req-1")
    check log.contains("share link key missing")
    check log.contains("0193f0e2-0000-7000-8000-000000000010")
    check log.contains("req-1")
    check log.contains("\"level\":\"error\"")

  test "the metric counts the key problem":
    check metricsText().contains("share_key_problems_total")

  test "re-displaying the link answers 503, not 'no live share link'":
    let response = call(baseUrl, HttpGet,
      "/c/" & slug & "/sessions/" & sessionId & "/share", hostCookie)
    check response.status == 503
    check parseJson(response.body)["code"].getStr() == "UNAVAILABLE"

# The row belongs to this suite; remove it so a standalone run leaves nothing
# sealed under a key the next file cannot read.
purgeCommunity(database, slug)
