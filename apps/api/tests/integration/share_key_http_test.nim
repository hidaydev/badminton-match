## BE-22: a live row whose key the process does not hold is a key problem, not
## a missing link.
##
## The row stays live while `SHARE_CODE_KEYS` no longer holds its `key_id`, which
## is exactly what a retirement without a rotation leaves behind. Answering 404
## ("the link was never created") sends the operator to issue a new link instead
## of restoring the key, so the request answers 503 and the process counts it.

import std/[json, os, strutils, unittest]
import db/db
import community/infrastructure/community_store
import share/crypto
import share/store as shareStore
import tests/fixtures
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

proc withCapturedStdout(work: proc()): string =
  ## The log line is written to stdout from the worker thread that serves the
  ## request, so the capture swaps the process stream around the call.
  let path = getTempDir() / ("majadu-sharekey-" & $getCurrentProcessId() & ".log")
  let saved = stdout
  stdout = open(path, fmWrite)
  try:
    work()
    stdout.flushFile()
  finally:
    stdout.close()
    stdout = saved
  result = readFile(path)
  removeFile(path)

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
    var status = 0
    var code = ""
    let log = withCapturedStdout(proc() =
      let response = call(baseUrl, HttpGet, "/s/" & liveCode)
      status = response.status
      if response.body.len > 0:
        code = parseJson(response.body)["code"].getStr())
    check status == 503
    check code == "UNAVAILABLE"
    check log.contains("share link key missing")
    check log.contains("linkId")
    # Never the code: the line is safe to keep and to ship to a log collector.
    check not log.contains(liveCode)

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
