## The three pre-context paths the security review found answering 200 with the
## wrong content once the policy set is on, proven against it.
##
## Every case here runs as `bm2_app` with the tenant setting unset, inside a
## transaction that is always rolled back: that is the shape a request has when
## it reaches one of these paths, and it is the shape a superuser DSN hides. On a
## database without the policies the same statements return the same rows through
## the plain pool, which is what makes step 1 invisible there.
##
##   1. `currentSettings` on the plain pool returns no row, so every community
##      override silently reverts to the platform default; through the facade that
##      declares the community it returns the stored values.
##   2. `GET /communities` has no `{slug}`, so no tenant is ever installed: the
##      membership join matches nothing. The loop the route now runs answers with
##      the caller's own memberships, ordered by slug.
##   3. `POST /communities` inserts the first-admin invitation into a table that
##      carries the policy while the transaction has no tenant: `with check`
##      refuses and the community row rolls back with it.

import std/[json, options, os, sequtils, unittest]
import db/db
import ../../src/community_context
import community/infrastructure/community_store
import tests/fixtures
import tests/app_role_fixture

const
  slugA = "scope-guc-a"
  slugB = "scope-guc-b"
  ## A value the platform default does not carry, so a read that fell back to it
  ## is visible in the answer rather than hidden by coincidence.
  overrideKey = "community.default_timezone"
  overrideValue = "Pacific/Kiritimati"

proc dsn(): string = getEnv("MAJADU_PG_DSN")

suite "pre-context reads under the policy set":
  var db: Db
  var communityA, communityB, memberOfBoth, memberOfAOnly: string

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    for slug in [slugA, slugB]:
      purgeCommunity(db, slug)
    discard db.execUpdate(
      "delete from platform.user where google_sub like 'scope-guc-%'")
    communityA = newCommunity(db, slugA, "Scope A")
    communityB = newCommunity(db, slugB, "Scope B")
    memberOfBoth = newUser(db, "scope-guc-both", "scope-both@example.com")
    memberOfAOnly = newUser(db, "scope-guc-a", "scope-a@example.com")
    newMember(db, communityA, memberOfBoth, "admin")
    newMember(db, communityB, memberOfBoth, "member")
    newMember(db, communityA, memberOfAOnly, "member")
    discard db.execUpdate(
      """insert into community.settings (community_id, values)
         values ($1::uuid, jsonb_build_object($2::text, $3::text))
         on conflict (community_id) do update set values = excluded.values""",
      @[textParam(communityA), textParam(overrideKey),
        textParam(overrideValue)])

  teardown:
    for slug in [slugA, slugB]:
      purgeCommunity(db, slug)
    discard db.execUpdate(
      "delete from platform.user where google_sub like 'scope-guc-%'")
    db.close()

  test "a community's settings survive the policy set on its own scope":
    # Driven through `loadCommunity`, the door every `/c/{slug}` request passes,
    # rather than a local copy of its statements: the settings read is inside it,
    # and a copy would keep passing after the door regressed.
    #
    # The policy on `community.settings` is what makes or breaks this. On a
    # database without it the plain-pool read happens to work, which is exactly
    # why step 1 is invisible there; with it on, that read returns no row, every
    # override silently falls back to the platform default, and the request is
    # still a 200.
    let policiesOn = db.queryOne(
      """select count(*)::int as n from pg_policies
         where schemaname = 'community' and tablename = 'settings'""")
      .get.getInt("n") > 0
    var ctxKeys: seq[string] = @[]
    var ctxValue = ""
    var plainKeys: seq[string] = @[]
    asApp(db, proc(app: Db, conn: DbConn) =
      # `loadCommunity` names a community before it reads anything scoped, so it
      # is safe to call with no tenant installed: that is the pre-context door.
      let ctx = loadCommunity(app, memberOfAOnly, slugA)
      check ctx.isSome
      ctxKeys = ctx.get.settings.keys.toSeq
      ctxValue = ctx.get.settings[overrideKey].getStr
      plainKeys = currentSettings(app, communityA).keys.toSeq)
    check ctxKeys == @[overrideKey]
    check ctxValue == overrideValue
    # The plain read is the shape the door used to have; it is only wrong once
    # the policy is on, which is what makes the fix load-bearing rather than
    # decorative.
    if policiesOn:
      check overrideKey notin plainKeys
    else:
      check plainKeys == ctxKeys

  test "the community list answers the caller's own memberships":
    # The loop `listCommunities` runs: the root table names the communities and
    # each role is read on a facade that declares one.
    proc listed(app: Db, userId: string): seq[string] =
      for community in app.query(
          "select id, slug, name from platform.community order by slug"):
        let communityId = community.get("id")
        let member = app.scoped(communityId).queryOne(
          """select role from community.membership
             where community_id = $1::uuid and user_id = $2::uuid""",
          @[textParam(communityId), textParam(userId)])
        if member.isNone:
          continue
        result.add(community.get("slug") & "/" & member.get.get("role"))

    var both, onlyA: seq[string] = @[]
    asApp(db, proc(app: Db, conn: DbConn) =
      both = listed(app, memberOfBoth)
      onlyA = listed(app, memberOfAOnly))
    # Both slugs, in the route's order, with the role from the membership row.
    check both == @[slugA & "/admin", slugB & "/member"]
    # A member of A is never told that B exists.
    check onlyA == @[slugA & "/member"]
    check slugB notin onlyA

  test "creating a community commits its first-admin invitation":
    # `create` opens its own transaction and inserts the invitation on the
    # caller's connection; under the policy set that insert must name the
    # community the transaction just created.
    var created = ""
    var status = csOk
    var invites = 0
    asApp(db, proc(app: Db, conn: DbConn) =
      let outcome = community_store.create(app, "scope-guc-new", "Scope New",
        "scope-new@example.com", "Asia/Jakarta", memberOfBoth)
      status = outcome.status
      created = outcome.communityId
      let scoped = app.scoped(created)
      invites = scoped.queryOne(
        """select count(*)::int as n from community.invite
           where community_id = $1::uuid""",
        @[textParam(created)]).get.getInt("n"))
    check status == csOk
    check created.len > 0
    check invites == 1

  test "a taken slug is refused with no partial rows":
    # The refusal path must not leave the platform.community row behind when the
    # invitation is what failed, and it must not answer ok for a slug that exists.
    var status = csOk
    var rows = -1
    asApp(db, proc(app: Db, conn: DbConn) =
      status = community_store.create(app, slugA, "Scope Taken",
        "scope-taken@example.com", "Asia/Jakarta", memberOfBoth).status
      rows = conn.queryOne(
        """select count(*)::int as n from platform.community
           where slug = $1""",
        @[textParam(slugA)]).get.getInt("n"))
    check status == csSlugTaken
    check rows == 1
