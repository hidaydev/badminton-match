## The create-community route under `MAJADU_ENV=prod`.
##
## ADR-018 allows one community per production database until RLS ships. The
## boot refuses a database that already holds two, which left the window this
## suite closes: a running process accepts a POST, writes community #2, and dies
## on the next restart. The route asks the same rule (`community/tenancy.nim`)
## inside the transaction that would insert, so the row never lands.
##
## The app is built with the environment named explicitly instead of the process
## env, because the boot assertions in `main.nim` read `MAJADU_ENV` and a suite
## must not look like a production process. Everything else in this file is
## ordinary: development and test databases keep creating communities, which
## `community_http_test.nim` still proves.

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
  slug = "limit-prod-club"
  ownerEmail = "limit-owner@example.com"

var
  database: Db
  ownerId: string
  ownerCookie: string

proc communityTotal(): int =
  parseInt(database.queryOne(
    "select count(*)::int as total from platform.community").get.get("total"))

proc bootstrap() =
  database = openDb(dsn(), 1)
  purgeCommunity(database, slug)
  cleanupUsers(database, "limit-%")
  ownerId = newUser(database, "limit-owner", ownerEmail, "Limit Owner",
    owner = true)
  ownerCookie = cookieFor(database, ownerId)
  # The one community this production database is allowed to hold.
  discard newCommunity(database, slug, "Limit Prod Club")
  startServer(newApp(database, OidcConfig(), loadKeyring(keysJson, "1"),
    newConfigCache(database), environment = "prod"), port, baseUrl)

bootstrap()

suite "creating a community in production":
  test "a second community is refused with 409 and writes no row":
    let before = communityTotal()
    check before >= 1
    # The dev path already proves the route answers 201 with `MAJADU_ENV`
    # unset; here the same request must be refused before the insert.
    let response = call(baseUrl, HttpPost, "/communities", ownerCookie,
      """{"slug":"limit-prod-second","name":"Second","adminEmail":"x@example.com"}""")
    checkpoint(response.body)
    check response.status == 409
    let body = parseJson(response.body)
    check body["code"].getStr() == "COMMUNITY_LIMIT"
    check body["i18nKey"].getStr() == "error.communityLimit"
    # The rule names the ADR and the document, like the boot refusal does.
    check body["detail"].getStr().contains("ADR-018")
    check body["detail"].getStr().contains("rls-tenancy-options.md")
    check communityTotal() == before
    check database.queryOne(
      "select 1 as one from platform.community where slug = 'limit-prod-second'")
      .isNone
