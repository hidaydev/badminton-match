## BE-18: the config snapshot is probed once per request and the community
## settings are read once, however many helpers the handler calls.
##
## The counts come from the driver's own statement log (`recordStatements`),
## enabled around one request, so the number asserted is that request's. Before
## the refactor a community read paid a second `select version` for the session
## lookup, a third for `bodyJson`, and a second `community.settings` read for a
## handler that needed the same row twice.

import std/unittest
import db/db
import community/infrastructure/community_store
import tests/fixtures
import ../http_support

let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  slug = "request-cost-club"
  hostEmail = "cost-host@example.com"

var
  database: Db
  communityId: string
  hostCookie: string

proc bootstrap() =
  database = openDb(dsn(), 1)
  purgeCommunity(database, slug)
  discard database.execUpdate(
    """delete from platform.idempotency_keys where user_id in
         (select id from platform.user where google_sub like 'cost-%')""")
  discard database.execUpdate(
    "delete from platform.user where google_sub like 'cost-%'")
  let ownerId = newUser(database, "cost-owner", "cost-owner@example.com",
    "Owner", owner = true)
  communityId = community_store.create(database, slug, "Request Cost Club",
    hostEmail, "Asia/Jakarta", ownerId).communityId
  let hostId = newUser(database, "cost-host", hostEmail, "Host")
  newMember(database, communityId, hostId, "host")
  discard newPlayer(database, communityId, "Cost Player")
  hostCookie = cookieFor(database, hostId)
  startServer(newTestApp(database), port, baseUrl)

bootstrap()

proc costOf(path: string): tuple[probes, settingsReads: int] =
  recordStatements(true)
  let response = call(baseUrl, HttpGet, path, hostCookie)
  result = (
    statementsMatching("select version from platform.config_version"),
    statementsMatching("from community.settings"))
  recordStatements(false)
  check response.status == 200

suite "request cost":
  test "the session list probes the version and reads settings once":
    let cost = costOf("/c/" & slug & "/sessions")
    check cost.probes == 1
    check cost.settingsReads == 1

  test "the ranking route probes the version and reads settings once":
    let cost = costOf("/c/" & slug & "/rankings")
    check cost.probes == 1
    check cost.settingsReads == 1

  test "the config route probes the version and reads settings once":
    let cost = costOf("/c/" & slug & "/config")
    check cost.probes == 1
    check cost.settingsReads == 1
