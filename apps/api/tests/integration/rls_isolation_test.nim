## The dynamic half of the RLS gate: what the application role can actually see.
##
## `policy_coverage_test` proves the policies are declared. This one proves they
## bind, which is a different question: a policy can exist and still be wrong
## (a reversed comparison, `using (true)`, a predicate on the wrong column), and
## every one of those failures returns a 200 with plausible rows.
##
## The subject is `bm2_app`, not the owner, because the owner bypasses row
## security (`enable`, never `force`) and would pass every case below while
## production leaked. That is the same reason the isolation matrix cannot be the
## RLS gate: it boots the app on a superuser DSN.
##
## Three cases, in the order a mistake would hurt:
##
##   1. **A set to community A.** Every tenant table returns exactly A's rows
##      and none of B's, and a write that names B is refused.
##   2. **No GUC at all.** The same reads return zero rows. Never B's. This is
##      the `:prev` case: an image from before step 1 sets no GUC, and a policy
##      that fails open here would serve the whole database to it.
##   3. **A write through the view.** `session.game_results` must inherit the
##      invoker's policies, so a read through it under A's GUC cannot see B's
##      games. Without `security_invoker` this returns B's rows while every
##      base-table check still passes.
##
## Each case runs inside `begin ... rollback` on one connection with `set local
## role bm2_app`, so nothing here can outlive the transaction or affect a
## neighbouring suite. `set_config(..., true)` is transaction-local for the same
## reason: a leaked GUC on a pooled connection is the bug this release exists to
## avoid, so the test must not become an example of it.

import std/[options, os, strutils, unittest]
import db/db
import tests/fixtures

# Importing the harness keeps DSN handling identical to every other integration
# suite; none of its HTTP helpers are used here.
import ../http_support

const
  ## Two communities, distinguished by slug so a failure names which one leaked.
  slugA = "rls-iso-a"
  slugB = "rls-iso-b"

  ## Every tenant table this suite checks. Ordered by schema then name so a
  ## failure list reads steadily. This list is deliberately explicit: the
  ## catalogue test derives its list from the catalogue and would catch a new
  ## table, while this one has to know how to seed and count each table, and a
  ## derived list would not tell it that.
  checkedTables = [
    "achievement.earned", "account.audit", "community.invite",
    "community.join_request", "community.membership", "community.settings",
    "import.row_map",
    "player.aliases", "player.claims", "player.merge_log", "player.players",
    "rating.events", "rating.levels", "rating.player_state",
    "rating.snapshots", "rating.sources", "session.courts", "session.game_sets",
    "session.game_skips", "session.games", "session.links", "session.participants",
    "session.sessions", "tournament.groups", "tournament.matches",
    "tournament.pairs", "tournament.team_matches", "tournament.team_partai",
    "tournament.team_players", "tournament.teams", "tournament.tournaments",
  ]

  ## The subset `seeded` actually populates. Kept next to `checkedTables` so the
  ## distance between "we guard 30 tables" and "we prove 7 of them with rows" is
  ## visible instead of implied.
  seededTables = [
    "player.players", "session.sessions", "session.games", "session.game_sets",
    "session.courts", "session.participants", "community.settings",
  ]

type
  Fixture = object
    communityA, communityB: string
    sessionA, sessionB: string
    ## Two per community: `games_distinct_sides` refuses a game that names the
    ## same player on both sides, so a one-player fixture cannot produce a
    ## played game and therefore not a single row for `session.games`.
    playerA1, playerA2, playerB1, playerB2: string

proc seeded(db: Db): Fixture =
  ## As few rows as possible that still make every checked table non-empty for
  ## both communities. A table with no rows in either community cannot prove
  ## anything, so the counts below are asserted to be greater than zero before
  ## the isolation case runs.
  result.communityA = newCommunity(db, slugA, "RLS isolation A")
  result.communityB = newCommunity(db, slugB, "RLS isolation B")

  result.playerA1 = newPlayer(db, result.communityA, "Player A1")
  result.playerA2 = newPlayer(db, result.communityA, "Player A2")
  result.playerB1 = newPlayer(db, result.communityB, "Player B1")
  result.playerB2 = newPlayer(db, result.communityB, "Player B2")

  result.sessionA = newSession(db, result.communityA, "Session A",
    status = "published", approved = true)
  result.sessionB = newSession(db, result.communityB, "Session B",
    status = "published", approved = true)

  # A played game per community so `session.games`, `session.game_sets` and the
  # `session.game_results` view all carry a row for each tenant. Participants are
  # written too: the standings and the absent flag read only that table, and it
  # is one of the 30 that must return zero rows for the other tenant.
  for (communityId, sessionId, first, second) in [
      (result.communityA, result.sessionA, result.playerA1, result.playerA2),
      (result.communityB, result.sessionB, result.playerB1, result.playerB2)]:
    newParticipant(db, communityId, sessionId, first)
    newParticipant(db, communityId, sessionId, second)
    newPlayedGame(db, communityId, sessionId, 1, 1,
      [first], [second], setScoreA = 21, setScoreB = 15,
      scoreA = 21, scoreB = 15)

  for communityId in [result.communityA, result.communityB]:
    discard db.execUpdate(
      """insert into community.settings (community_id, values)
         values ($1::uuid, '{}'::jsonb)
         on conflict (community_id) do nothing""",
      @[textParam(communityId)])

proc countFor(db: Db, table, communityId: string): int =
  ## Rows of one community in one table, as the owner. Used once per table to
  ## prove the fixture is not vacuous; the isolation case counts as `bm2_app`
  ## instead, and a mismatch between the two counts is the whole subject.
  let row = db.queryOne(
    "select count(*)::int as n from " & table & " where community_id = $1::uuid",
    @[textParam(communityId)])
  if row.isNone: 0 else: row.get.getInt("n")

proc canAssumeAppRole(conn: DbConn): bool =
  ## Whether this connection's role may `set role bm2_app`. A superuser may, and
  ## so may a role that is a member of `bm2_app`; `bm2_owner` is neither, which
  ## is why the suite cannot be run on the owner DSN.
  ##
  ## It takes the connection it is asked about rather than a `Db`: this suite
  ## opens a pool of one, and a helper that checked out a second connection while
  ## the first was held would wait until the acquire timeout and fail with a
  ## message about the pool instead of about the role.
  let row = conn.queryOne(
    """select (select rolsuper from pg_roles where rolname = current_user)
              or pg_has_role(current_user, 'bm2_app', 'member') as allowed""")
  row.isSome and row.get.getBool("allowed")

proc runAsApp(db: Db, communityId: string, body: proc(conn: DbConn)) =
  ## Runs `body` as `bm2_app` with the tenant GUC set to `communityId`, inside a
  ## transaction that is always rolled back.
  ##
  ## `set local role` is the shortest path that makes the policies bind. It needs
  ## the calling role to be a superuser or a member of `bm2_app`; `bm2_app` itself
  ## is NOLOGIN, which does not block assuming it. That requirement is asserted
  ## up front instead of surfacing later as a `DbError` from inside a probe.
  ##
  ## The boundary is written out rather than borrowed from `db.tx`, because
  ## `txRet` commits on a normal return: every caller here is a probe, and a
  ## probe that committed would leave rows behind exactly on the failure path
  ## this suite is meant to catch. The GUC is written with
  ## `set_config(..., true)`, so it dies with the transaction either way.
  discard db.read(proc(conn: DbConn): bool =
    doAssert canAssumeAppRole(conn),
      "this suite needs a DSN whose role is a superuser or a member of bm2_app"
    # `execUpdate`, not `query`: these are commands with no result rows, and
    # `query` refuses anything that is not a tuple result.
    discard conn.execUpdate("begin")
    try:
      discard conn.execUpdate("set local role bm2_app")
      discard conn.query("select set_config('majadu.community_id', $1, true)",
        @[textParam(communityId)])
      body(conn)
      false
    finally:
      discard conn.execUpdate("rollback"))

proc auditProbe(db: Db, communityId, marker: string): tuple[state: string, visible: int] =
  ## Writes one `account.audit` row in the shape `denyAudit` uses, as `bm2_app`,
  ## with the tenant GUC at `communityId`, then reads it back **inside the same
  ## transaction**. Both halves matter:
  ##
  ##   * the insert proves `with check` admits a row whose `community_id`
  ##     matches the GUC, which is what a refusal has to be able to write;
  ##   * the read-back proves the row is actually there under the policy, so an
  ##     insert that reported success but landed nowhere cannot pass.
  ##
  ## The boundary is written out rather than borrowed from `runAsApp`, because
  ## `runAsApp` discards its body's result and this probe needs two answers from
  ## one transaction. It rolls back for the same reason: a probe that committed
  ## would leave audit rows behind on the failure path.
  var state = ""
  var visible = -1
  discard db.read(proc(conn: DbConn): bool =
    doAssert canAssumeAppRole(conn),
      "this suite needs a DSN whose role is a superuser or a member of bm2_app"
    discard conn.execUpdate("begin")
    try:
      discard conn.execUpdate("set local role bm2_app")
      discard conn.query("select set_config('majadu.community_id', $1, true)",
        @[textParam(communityId)])
      try:
        discard conn.execUpdate(
          """insert into account.audit
               (actor_role, community_id, action, target_kind, target_id,
                result, request_id)
             values ('member', $1::uuid, $2, 'session', 'probe', 'deny', 'probe')""",
          @[textParam(communityId), textParam(marker)])
      except DbError as error:
        state = error.sqlState
      if state.len == 0:
        let row = conn.queryOne(
          "select count(*)::int as n from account.audit where action = $1",
          @[textParam(marker)])
        if row.isSome:
          visible = row.get.getInt("n")
      false
    finally:
      discard conn.execUpdate("rollback"))
  (state: state, visible: visible)

proc auditRefusedWithoutGuc(db: Db, communityId, marker: string): string =
  ## The same insert the refusal handler makes, with the tenant setting never
  ## written at all. That is what a statement outside a scoped facade looks
  ## like, and the policy must refuse it: the row names a community while the
  ## tenant is NULL, so `community_id = session.tenant_id()` is NULL.
  ##
  ## The community is named deliberately. `account.audit` admits a NULL
  ## `community_id` on purpose (a platform-level action and a login refusal have
  ## no community), so writing NULL here would be allowed and would prove
  ## nothing. The defect this catches is the one that matters: a handler that
  ## forgot to scope itself must not land its row.
  var state = "99999"
  discard db.read(proc(conn: DbConn): bool =
    doAssert canAssumeAppRole(conn),
      "this suite needs a DSN whose role is a superuser or a member of bm2_app"
    discard conn.execUpdate("begin")
    try:
      discard conn.execUpdate("set local role bm2_app")
      try:
        discard conn.execUpdate(
          """insert into account.audit
               (actor_role, community_id, action, target_kind, target_id,
                result, request_id)
             values ('member', $1::uuid, $2, 'session', 'probe', 'deny',
                     'probe')""",
          @[textParam(communityId), textParam(marker)])
        state = ""
      except DbError as error:
        state = error.sqlState
      false
    finally:
      discard conn.execUpdate("rollback"))
  state

proc appIds(db: Db, table, communityId: string): seq[string] =
  ## What `bm2_app` can see in one table under one tenant's GUC, identified by
  ## the community id each row carries. Returning the ids rather than a count
  ## is what lets a failure say "B leaked" instead of "expected 1, got 2".
  var ids: seq[string] = @[]
  runAsApp(db, communityId, proc(conn: DbConn) =
    for row in conn.query(
      "select community_id::text as id from " & table & " order by 1"):
      ids.add(row.get("id")))
  ids

suite "RLS isolation as the application role":
  let db = openDb(dsn(), 1)
  var fixture: Fixture

  setup:
    # One fixture for the whole suite: the cases only read, and rebuilding it
    # per case would make the suite slower without proving anything more.
    if fixture.communityA.len == 0:
      fixture = seeded(db)

  teardown:
    # `purgeCommunity` reads the catalogue, so it removes a community's rows
    # from every table without a hand-kept list to drift from the schema.
    if fixture.communityA.len > 0:
      purgeCommunity(db, slugA)
      purgeCommunity(db, slugB)
      fixture = Fixture()

  test "the fixture put at least one row of each community where it seeds one":
    # The isolation case is only as strong as its data: a table with no row for
    # B cannot prove B is invisible. The tables this fixture populates are
    # asserted non-empty, and the ones it leaves empty are named so nobody reads
    # an empty table as coverage. Both lists are checked, so a table silently
    # dropping out of the fixture does not quietly weaken the suite.
    var empty: seq[string] = @[]
    for table in seededTables:
      if countFor(db, table, fixture.communityA) == 0:
        empty.add(table & " (A)")
      if countFor(db, table, fixture.communityB) == 0:
        empty.add(table & " (B)")
    checkpoint("seeded but empty: " & empty.join(", "))
    check empty.len == 0

    # Nothing outside the fixture's reach carries rows, so the isolation case
    # below cannot pass on data it did not create.
    var stray: seq[string] = @[]
    for table in checkedTables:
      if table in seededTables:
        continue
      if countFor(db, table, fixture.communityA) > 0 or
         countFor(db, table, fixture.communityB) > 0:
        stray.add(table)
    checkpoint("unseeded but non-empty: " & stray.join(", "))
    check stray.len == 0

  test "with the GUC at A, every tenant table returns only A's rows":
    # Every one of the 30 is read under A's GUC: B's id in any of them is a
    # leak, and that holds for the tables the fixture never fills too, because
    # a row it never wrote is not there to be seen. Only the seeded tables are
    # required to return something, so an empty unseeded table is not a failure
    # here (the previous case already proved they are empty for both sides).
    var leaks: seq[string] = @[]
    var empty: seq[string] = @[]
    for table in checkedTables:
      let visible = appIds(db, table, fixture.communityA)
      if visible.len == 0 and table in seededTables:
        empty.add(table)
      for id in visible:
        if id == fixture.communityB:
          leaks.add(table)
          break
    checkpoint("B visible in: " & leaks.join(", "))
    checkpoint("seeded but invisible to A: " & empty.join(", "))
    check leaks.len == 0
    check empty.len == 0

  test "with no GUC at all, every tenant table returns zero rows and never B's":
    # The `:prev` case. An image from before step 1 sets no GUC; if the
    # predicate fails open, that image serves the whole database and
    # `/readyz`, `/version` and the smoke test all stay green.
    var visibleSomewhere: seq[string] = @[]
    var sawB: seq[string] = @[]
    for table in checkedTables:
      let visible = appIds(db, table, "")
      if visible.len > 0:
        visibleSomewhere.add(table & "=" & $visible.len)
      if fixture.communityB in visible:
        sawB.add(table)
    checkpoint("rows visible with no GUC: " & visibleSomewhere.join(", "))
    checkpoint("B visible with no GUC: " & sawB.join(", "))
    check visibleSomewhere.len == 0
    check sawB.len == 0

  test "the session.game_results view does not serve B under A's GUC":
    # The view carries `community_id` and would run as its owner without
    # `security_invoker`, so it is the one read that could bypass the policies
    # on the base tables while they all look correct.
    let visible = appIds(db, "session.game_results", fixture.communityA)
    checkpoint(visible.join(", "))
    check fixture.communityB notin visible
    check fixture.communityA in visible

  test "a write that names another community is refused":
    # `with check` is the half that stops a cross-tenant write, and it is the
    # half a `using`-only policy would miss. The insert names B while the GUC
    # says A, which is exactly what a missing `where` in an insert would do.
    #
    # The error identity matters: SQLSTATE 42501 is "insufficient privilege",
    # which is what a `with check` violation reports. A bare `except DbError`
    # would also pass on a role that could not be assumed or a missing column,
    # so the state is asserted rather than the exception's existence.
    var state = ""
    try:
      runAsApp(db, fixture.communityA, proc(conn: DbConn) =
        discard conn.execUpdate(
          """insert into session.sessions
               (community_id, title, session_date, status, source)
             values ($1::uuid, 'cross-tenant write', current_date, 'draft', 'manual')""",
          @[textParam(fixture.communityB)]))
    except DbError as error:
      state = error.sqlState
    checkpoint("sqlstate: " & state)
    check state == "42501"

  test "a refusal audit row lands under A's GUC and is refused without one":
    # This is the case that proves step 1's fix actually writes under policies.
    # `denyAudit` records a refusal with the community the request was scoped to,
    # so the row must pass `with check` when the GUC matches it. Run twice:
    #
    #   * GUC at A: the insert succeeds AND the row is readable, so a policy that
    #     silently dropped it (or a `with check` that reported success without
    #     storing) fails here.
    #   * no GUC at all: the same insert is refused with SQLSTATE 42501, because
    #     a refusal handler that loses its tenant must not be able to write an
    #     unscoped audit row either.
    #
    # `account.audit` is the one table whose `with check` admits a NULL
    # community, on purpose: a platform-level action and a login refusal have no
    # community to name. So the unset case writes A's id, not NULL. Writing NULL
    # would be allowed by the policy and would prove nothing; naming A with no
    # tenant is exactly the row a refusal handler that forgot to scope would
    # try to land.
    let marker = "rls-iso-audit-" & $getCurrentProcessId()
    let scoped = auditProbe(db, fixture.communityA, marker)
    checkpoint("scoped insert state: '" & scoped.state & "', visible: " &
      $scoped.visible)
    check scoped.state == ""
    check scoped.visible == 1

    let unscoped = auditRefusedWithoutGuc(db, fixture.communityA,
      marker & "-unset")
    checkpoint("unscoped insert sqlstate: '" & unscoped & "'")
    check unscoped == "42501"

    # Neither probe committed: the rolls back above are the reason the next run
    # of this suite on the same database starts clean.
    let leftover = db.queryOne(
      "select count(*)::int as n from account.audit where action like $1",
      @[textParam(marker & "%")])
    check leftover.isSome
    if leftover.isSome:
      check leftover.get.getInt("n") == 0

  test "a write that names its own community lands":
    # The negative of the previous case, so a policy that refuses everything
    # (a typo in the predicate) cannot pass this suite. The insert is rolled
    # back by `runAsApp`.
    var inserted = -1
    runAsApp(db, fixture.communityA, proc(conn: DbConn) =
      inserted = conn.execUpdate(
        """insert into session.sessions
             (community_id, title, session_date, status, source)
           values ($1::uuid, 'same-tenant write', current_date, 'draft', 'manual')""",
        @[textParam(fixture.communityA)]))
    check inserted == 1

  test "an update that matches another community changes nothing":
    # The read path of `with check` on an existing row: RLS makes B's rows
    # invisible, so an update that names B matches zero rows instead of
    # raising. Zero is the safe answer, and the row must still be there.
    var updated = -1
    runAsApp(db, fixture.communityA, proc(conn: DbConn) =
      updated = conn.execUpdate(
        "update session.sessions set title = 'stolen' where community_id = $1::uuid",
        @[textParam(fixture.communityB)]))
    check updated == 0
    let title = db.queryOne(
      "select title from session.sessions where community_id = $1::uuid",
      @[textParam(fixture.communityB)])
    check title.isSome
    if title.isSome:
      check title.get.get("title") == "Session B"

  test "the application role cannot see platform tables that carry no tenant":
    # `platform.community` has no policy on purpose: it is the tenant root, and
    # a request must read it by slug before a GUC exists. That means it stays
    # visible under any GUC, which is intended and asserted so the exemption is
    # a decision rather than an oversight.
    var communities = -1
    runAsApp(db, fixture.communityA, proc(conn: DbConn) =
      let row = conn.queryOne(
        "select count(*)::int as n from platform.community")
      if row.isSome:
        communities = row.get.getInt("n"))
    check communities >= 2

  db.close()
