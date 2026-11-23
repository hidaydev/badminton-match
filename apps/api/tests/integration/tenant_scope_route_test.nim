## The three pre-context paths the security review found, driven through the
## real routes on a pool that connects as `bm2_app`.
##
## This is the step-2 rehearsal for step 1. Every other suite boots the app on
## the developer's own role, and in CI on `postgres`; both are superusers, which
## bypass row security (the policy set enables it and never forces it). A route
## that lost its tenant scoping therefore answers 200 with the wrong content and
## every assertion on that DSN still passes.
##
## Cases, each one a 200-with-wrong-content before the fix:
##
##   1. `GET /c/{slug}/config` — the settings read runs on the plain pool, so
##      every override falls back to the platform default.
##   2. `GET /communities` — the route has no `{slug}`, so no tenant is ever
##      installed and the membership join matches nothing.
##   3. `POST /communities` — the first-admin invitation is written on a
##      transaction with no tenant, `with check` refuses it, and the whole
##      community rolls back as a 500.
##
## Skipped, not failed, when the database is openable by the app role but has no
## policy set: without policies the three paths answer correctly on the old code
## too, so they prove nothing. The point of this file is the policy set.

import std/[httpclient, json, options, strutils, unittest]
import db/db
import tests/fixtures
import ../http_support

const
  slugA = "scope-route-a"
  slugB = "scope-route-b"
  overrideKey = "community.default_timezone"
  overrideValue = "Pacific/Kiritimati"
  ## The app pool connects with this, so every statement the routes issue runs
  ## as the role production uses. `openDb` takes the connection string as-is.
  appRoleOption = "options=-c%20role%3Dbm2_app"

let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)

proc appDsn(raw: string): string =
  ## The same database, reached through the application role. The separator has
  ## to respect a query string the caller already put on the DSN.
  let query = raw.find('?')
  let (head, tail) =
    if query >= 0: (raw[0 ..< query], raw[query + 1 .. ^1])
    else: (raw, "")
  if tail.len > 0: head & "?" & tail & "&" & appRoleOption
  else: head & "?" & appRoleOption

suite "pre-context routes as the application role":
  var owner: Db
  var appPool: Db
  var policiesOn = false
  var communityA, communityB: string
  var memberOfBoth, memberOfAOnly, ownerUser: string
  var memberCookie, adminCookie, ownerCookie: string

  setup:
    let raw = dsn()
    if raw.len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    owner = openDb(raw, 1)
    policiesOn = owner.queryOne(
      """select count(*)::int as n from pg_policies
         where schemaname = 'community' and tablename = 'settings'""")
      .get.getInt("n") > 0
    for slug in [slugA, slugB, slugA & "-new"]:
      purgeCommunity(owner, slug)
    discard owner.execUpdate(
      "delete from platform.user where google_sub like 'scope-route-%'")
    communityA = newCommunity(owner, slugA, "Scope Route A")
    communityB = newCommunity(owner, slugB, "Scope Route B")
    memberOfBoth = newUser(owner, "scope-route-both", "scope-route-both@example.com")
    memberOfAOnly = newUser(owner, "scope-route-a", "scope-route-a@example.com")
    ownerUser = newUser(owner, "scope-route-owner", "scope-route-owner@example.com",
      owner = true)
    newMember(owner, communityA, memberOfBoth, "admin")
    newMember(owner, communityB, memberOfBoth, "member")
    newMember(owner, communityA, memberOfAOnly, "member")
    discard owner.execUpdate(
      """insert into community.settings (community_id, values)
         values ($1::uuid, jsonb_build_object($2::text, $3::text))
         on conflict (community_id) do update set values = excluded.values""",
      @[textParam(communityA), textParam(overrideKey),
        textParam(overrideValue)])
    memberCookie = cookieFor(owner, memberOfAOnly)
    adminCookie = cookieFor(owner, memberOfBoth)
    ownerCookie = cookieFor(owner, ownerUser)
    appPool = openDb(appDsn(raw), 4)
    startServer(newTestApp(appPool), port, baseUrl)

  teardown:
    for slug in [slugA, slugB, slugA & "-new"]:
      purgeCommunity(owner, slug)
    discard owner.execUpdate(
      "delete from platform.user where google_sub like 'scope-route-%'")
    appPool.close()
    owner.close()

  test "a community's settings reach the route on its own scope":
    let response = call(baseUrl, HttpGet, "/c/" & slugA & "/config", memberCookie)
    let body = response.body
    expectStatus(response, 200)
    let effective = parseJson(body)["effective"]
    # The override the community configured, and the route naming it as the
    # source: with the plain-pool read this entry said `platform` and carried
    # the platform default, which is the silent revert the fix removes.
    check effective.hasKey(overrideKey)
    check effective[overrideKey]["value"].getStr() == overrideValue
    check effective[overrideKey]["source"].getStr() == "community"

  test "the community list answers the caller's own memberships":
    let mine = call(baseUrl, HttpGet, "/communities", memberCookie)
    let mineBody = mine.body
    expectStatus(mine, 200)
    let items = parseJson(mineBody)["items"]
    check items.len == 1
    check items[0]["slug"].getStr() == slugA
    check items[0]["role"].getStr() == "member"
    # Two memberships, ordered by slug, and the other community is never named
    # to the member of one.
    let both = call(baseUrl, HttpGet, "/communities", adminCookie)
    let bothBody = both.body
    expectStatus(both, 200)
    let bothItems = parseJson(bothBody)["items"]
    check bothItems.len == 2
    check bothItems[0]["slug"].getStr() == slugA
    check bothItems[1]["slug"].getStr() == slugB
    check slugB notin mineBody

  test "creating a community commits its first-admin invitation":
    let body = """{"slug":"""" & slugA & """-new","name":"Scope New",""" &
      """"adminEmail":"scope-route-new@example.com"}"""
    let created = call(baseUrl, HttpPost, "/communities", ownerCookie, body)
    let createdBody = created.body
    expectStatus(created, 201)
    let newId = parseJson(createdBody)["id"].getStr()
    # Both rows, read back by the owner: the community and its invitation.
    check owner.queryOne(
      "select count(*)::int as n from platform.community where id = $1::uuid",
      @[textParam(newId)]).get.getInt("n") == 1
    check owner.queryOne(
      """select count(*)::int as n from community.invite
         where community_id = $1::uuid""",
      @[textParam(newId)]).get.getInt("n") == 1

  test "a taken slug is still a 409 with no partial rows":
    let body = """{"slug":"""" & slugA & """","name":"Taken",""" &
      """"adminEmail":"scope-route-taken@example.com"}"""
    let refused = call(baseUrl, HttpPost, "/communities", ownerCookie, body)
    let refusedBody = refused.body
    expectProblem(refused, 409, "SLUG_TAKEN")
    check owner.queryOne(
      """select count(*)::int as n from community.invite
         where email_hash is not null and community_id = $1::uuid""",
      @[textParam(communityA)]).get.getInt("n") == 0
