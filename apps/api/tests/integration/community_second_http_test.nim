## Creating a second community in one database.
##
## Multi-community is the supported shape: the create route writes the row, and
## the community it creates is isolated from the one that was already there. The
## isolation itself is the contract-walked matrix
## (`community_isolation_matrix_test.nim`); this suite proves the door, and that
## what walks through it starts empty.

import std/[json, options, strutils, unittest]
import db/db
import account/infrastructure/oidc
import platform/config/store
import share/crypto
import tests/fixtures
import ../http_support
import ../../src/app

let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)

const
  slug = "second-club"
  secondSlug = "second-club-two"
  ownerEmail = "second-owner@example.com"
  secondAdminEmail = "second-admin@example.com"

var
  database: Db
  ownerId: string
  ownerCookie: string
  firstSession: string

proc communityTotal(): int =
  parseInt(database.queryOne(
    "select count(*)::int as total from platform.community").get.get("total"))

proc bootstrap() =
  database = openDb(dsn(), 1)
  for name in [slug, secondSlug]:
    purgeCommunity(database, name)
  cleanupUsers(database, "second-%")
  ownerId = newUser(database, "second-owner", ownerEmail, "Second Owner",
    owner = true)
  ownerCookie = cookieFor(database, ownerId)
  let firstId = newCommunity(database, slug, "Second Club")
  firstSession = newSession(database, firstId, "First Night",
    sessionDate = "2026-11-23")
  startServer(newApp(database, OidcConfig(), loadKeyring(keysJson, "1"),
    newConfigCache(database)), port, baseUrl)

bootstrap()

suite "creating a second community":
  test "the route writes the row and the new community is isolated":
    let before = communityTotal()
    let response = call(baseUrl, HttpPost, "/communities", ownerCookie,
      """{"slug":"second-club-two","name":"Second Club Two","adminEmail":"""" &
        secondAdminEmail & "\"}")
    checkpoint(response.body)
    check response.status == 201
    let body = parseJson(response.body)
    let secondId = body["id"].getStr()
    check body["slug"].getStr() == secondSlug
    check communityTotal() == before + 1
    check database.queryOne(
      "select 1 as one from platform.community where slug = $1",
      @[textParam(secondSlug)]).isSome

    # A session scoped to the new community reads nothing of the first one,
    # including a row addressable by id.
    let secondAdmin = newUser(database, "second-admin", secondAdminEmail,
      "Second Admin")
    newMember(database, secondId, secondAdmin, "admin")
    let secondCookie = cookieFor(database, secondAdmin)
    let ownPlayers = call(baseUrl, HttpGet, "/c/" & secondSlug & "/players",
      secondCookie)
    check ownPlayers.status == 200
    check "First Night" notin ownPlayers.body
    let foreign = call(baseUrl, HttpGet,
      "/c/" & secondSlug & "/sessions/" & firstSession, secondCookie)
    checkpoint(foreign.body)
    check foreign.status in [400, 403, 404, 409, 412]
    check "First Night" notin foreign.body
