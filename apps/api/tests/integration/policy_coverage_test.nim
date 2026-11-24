## The static half of the RLS gate: does the database's own catalogue agree that
## tenancy is enforced?
##
## Read from `pg_class`, `pg_policy` and `pg_proc` rather than from a hand-kept
## list, so a tenant table added in a later migration fails here on the day it
## ships instead of after a leak. That is the whole point: the isolation matrix
## covers the routes, and this covers the tables the routes do not have to go
## through.
##
## What it asserts, and why each one is a real defect if it fails:
##
##   * every base table carrying `community_id`, `community.membership`
##     included, has row security on and at least one policy. A tenant table
##     without row security is unguarded: every statement that forgets a `where`
##     reads it.
##   * `relforcerowsecurity` is false everywhere. The owner is meant to bypass;
##     a forced table would break migrations, `dbtools seed`, `ownerseed` and
##     every operator tool that runs on the owner DSN.
##   * every view carrying `community_id`, derived from `pg_class`, runs with
##     `security_invoker`. Without it the view runs as its owner and keeps
##     serving every community's rows beside a complete policy set, so the guard
##     has a hole shaped exactly like the view.
##   * `account.audit` admits a NULL community for `bm2_app`, because a
##     platform-level action and a refused login have no community to name, and
##     the refusal must still be audited.
##   * no table outside the tenant set has row security on. Today that set is
##     the platform, auth, account-session and dbtools tables; switching one on
##     by accident turns that feature into a silent empty result.
##   * the cross-tenant read functions exist, are owned by the owner, are
##     SECURITY DEFINER, pin `search_path`, and are not executable by PUBLIC,
##     and the set of them is exactly the reviewed three: a fourth definer
##     function is a cross-tenant read nobody signed off on.
##
## Nothing here needs a fixture and nothing here writes: it is a catalogue read,
## so it runs in a second and cannot fail for a reason other than the schema.

import std/[options, sequtils, strutils, unittest]
import db/db

# Importing the harness keeps the DSN handling identical to every other
# integration suite; none of its HTTP helpers are used here.
import ../http_support

const
  ## The membership lookup that cannot work through a policy, because it is the
  ## query that discovers *which* community a slug names. `loadCommunity` joins
  ## `community.membership` to `platform.community` by slug before a community
  ## id exists, and the row that names the community is the row the GUC would
  ## have to be read from. So `community.membership` now carries the standard
  ## policy like every other tenant table, and this function is the one
  ## legitimate read past it. Asserted as a signature, not as an exemption: an
  ## exemption here would leave membership readable by every statement.
  membershipContextSignature = "community.membership_context(text,uuid)"

  ## The SECURITY DEFINER functions from 0061, with the argument types `pg_proc`
  ## records. Spelled out because `regprocedure` needs them and a signature
  ## change should fail loudly here. The list is asserted to be *exactly* this
  ## set, so a fourth definer function cannot appear without a deliberate edit:
  ## each one is a cross-tenant read, and an extra one is a hole nobody reviewed.
  definerFunctions = [
    "session.share_link_resolve(bytea,uuid)",
    "community.invite_by_token(bytea)",
    membershipContextSignature,
  ]

type
  TenantTable = object
    qualified: string
    rlsOn: bool
    forced: bool
    policies: int

proc tenantTables(db: Db): seq[TenantTable] =
  ## Every base table with a `community_id` column, straight from the catalogue.
  ## `attnum > 0` and `not attisdropped` keep a dropped-then-recreated column
  ## from counting twice.
  for row in db.query(
    """select n.nspname || '.' || c.relname                  as qualified,
              c.relrowsecurity                              as rls_on,
              c.relforcerowsecurity                         as forced,
              (select count(*)::int from pg_policy p where p.polrelid = c.oid) as policies
         from pg_class c
         join pg_namespace n on n.oid = c.relnamespace
        where c.relkind = 'r'
          and n.nspname not in ('pg_catalog', 'information_schema')
          and exists (
            select 1 from pg_attribute a
             where a.attrelid = c.oid
               and a.attname = 'community_id'
               and a.attnum > 0
               and not a.attisdropped)
        order by 1"""):
    result.add(TenantTable(
      qualified: row.get("qualified"),
      rlsOn: row.getBool("rls_on"),
      forced: row.getBool("forced"),
      policies: row.getInt("policies")))

proc tablesWithRls(db: Db): seq[string] =
  ## Every base table that has row security on, tenant or not. Used to prove
  ## nothing outside the tenant set was switched on by accident.
  for row in db.query(
    """select n.nspname || '.' || c.relname as qualified
         from pg_class c
         join pg_namespace n on n.oid = c.relnamespace
        where c.relkind = 'r'
          and n.nspname not in ('pg_catalog', 'information_schema')
          and c.relrowsecurity
        order by 1"""):
    result.add(row.get("qualified"))

proc tenantViews(db: Db): seq[string] =
  ## Every view that exposes a `community_id` column, straight from the
  ## catalogue, so a view added by a later migration is checked on the day it
  ## ships instead of the day someone remembers to add it to a list.
  ## `attnum > 0` and `not attisdropped` keep a dropped-then-recreated column
  ## from counting twice, the same guard the table query uses.
  for row in db.query(
    """select n.nspname || '.' || c.relname as qualified
         from pg_class c
         join pg_namespace n on n.oid = c.relnamespace
        where c.relkind in ('v', 'm')
          and n.nspname not in ('pg_catalog', 'information_schema')
          and exists (
            select 1 from pg_attribute a
             where a.attrelid = c.oid
               and a.attname = 'community_id'
               and a.attnum > 0
               and not a.attisdropped)
        order by 1"""):
    result.add(row.get("qualified"))

proc viewRunsAsInvoker(db: Db, view: string): string =
  ## "" when the view carries `security_invoker=true`, otherwise a sentence
  ## saying what it has. A view without it runs as its owner and serves every
  ## community's rows beside a complete policy set.
  let row = db.queryOne(
    """select coalesce(array_to_string(c.reloptions, ','), '') as options
         from pg_class c
         join pg_namespace n on n.oid = c.relnamespace
        where n.nspname || '.' || c.relname = $1""",
    @[textParam(view)])
  if row.isNone:
    return "view not found"
  let options = row.get.get("options").split(',').mapIt(it.strip)
  if "security_invoker=true" in options:
    return ""
  if options.len == 0 or options == @[""]:
    return "no reloptions, so it runs as its owner"
  "reloptions are {" & row.get.get("options") & "}"

proc actualDefinerFunctions(db: Db): seq[string] =
  ## Every SECURITY DEFINER function in the schemas this migration owns, as
  ## `schema.name(args)` with `pg_proc`'s type names. The assertions below say
  ## the set is *exactly* the three expected ones, so this is what catches a
  ## fourth: each definer function is a cross-tenant read and an unreviewed one
  ## is a hole, not a convenience.
  #
  # `oidvectortypes` renders the argument *types* only; the identity-argument
  # helper includes parameter names, which would make the comparison below about
  # spelling rather than about the signature callers can reach.
  for row in db.query(
    """select n.nspname || '.' || p.proname || '(' ||
              replace(oidvectortypes(p.proargtypes), ' ', '') || ')' as signature
         from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
        where p.prosecdef
          and n.nspname in ('session', 'community', 'platform', 'player',
                            'rating', 'tournament', 'achievement', 'import',
                            'account')
        order by 1"""):
    result.add(row.get("signature"))

proc policyCount(db: Db, table, role: string): int =
  ## Policies on one table that name one role. `pg_policy.polroles` holds role
  ## oids; `0` is PUBLIC. A policy with no role list is PUBLIC and must not be
  ## counted as this role's.
  let row = db.queryOne(
    """select count(*)::int as n
         from pg_policy p
         join pg_class c on c.oid = p.polrelid
         join pg_namespace n on n.oid = c.relnamespace
        where n.nspname || '.' || c.relname = $1
          and exists (
            select 1 from unnest(p.polroles) as r
             where r = (select oid from pg_roles where rolname = $2))""",
    @[textParam(table), textParam(role)])
  if row.isNone: 0 else: row.get.getInt("n")

proc auditAppQual(db: Db): string =
  ## The `using` expression of the `bm2_app` policy on `account.audit`, as
  ## PostgreSQL itself renders it.
  let row = db.queryOne(
    """select pg_get_expr(p.polqual, p.polrelid) as qual
         from pg_policy p
        where p.polrelid = 'account.audit'::regclass
          and (select oid from pg_roles where rolname = 'bm2_app') = any(p.polroles)
        order by 1
        limit 1""")
  if row.isNone: "" else: row.get.get("qual")

proc definerFunctionProblem(db: Db, signature: string): string =
  ## One sentence per contract the function breaks, or "" when it is correct.
  ##
  ## Ownership is compared against the tenant tables rather than against the
  ## literal `bm2_owner`: production migrates as `bm2_owner` and CI migrates as
  ## the superuser, and in both the property that matters is the same one — the
  ## definer must be the role that owns the tables, because that is what lets it
  ## read past the policies and what makes `force` unnecessary. Asserting the
  ## name would pass in production and fail in CI for no real defect.
  let row = db.queryOne(
    """select pg_get_userbyid(p.proowner)                                  as owner,
              p.prosecdef                                                 as secdef,
              coalesce(array_to_string(p.proconfig, ', '), '')            as config,
              coalesce(array_to_string(p.proacl, ' '), '')                as acl,
              has_function_privilege('public', p.oid, 'EXECUTE')          as public_exec,
              (select pg_get_userbyid(c.relowner)
                 from pg_class c
                where c.oid = 'session.sessions'::regclass)               as table_owner
         from pg_proc p
        where p.oid = $1::regprocedure""",
    @[textParam(signature)])
  if row.isNone:
    return "missing"
  let value = row.get
  if value.get("owner") != value.get("table_owner"):
    return "owner is " & value.get("owner") & ", but the tenant tables belong to " &
      value.get("table_owner") & ", so it does not read past the policies"
  if not value.getBool("secdef"):
    return "not SECURITY DEFINER, so it cannot read past the policies"
  if not value.get("config").contains("search_path"):
    return "does not pin search_path, so a caller controls name resolution inside it"
  if value.getBool("public_exec"):
    return "executable by PUBLIC, so every role inherits the cross-tenant read"
  ""

suite "RLS policy coverage":
  let db = openDb(dsn(), 1)

  test "the catalogue has tenant tables to check":
    # A vacuously passing suite is worse than a red one: if the query that
    # discovers tenant tables broke, every assertion below would iterate an
    # empty list and pass.
    let tables = tenantTables(db)
    check tables.len == 31
    check tables.filterIt(it.qualified == "community.membership").len == 1

  test "every tenant table, membership included, has row security and a policy":
    # No exemption. `community.membership` is guarded like the other 30; the
    # read that cannot pass through the policy goes through a definer function
    # asserted below, not through a hole in the catalogue.
    var missing: seq[string] = @[]
    for table in tenantTables(db):
      if not table.rlsOn:
        missing.add(table.qualified & ": row security off")
      elif table.policies == 0:
        missing.add(table.qualified & ": no policy")
    checkpoint(missing.join("\n"))
    check missing.len == 0

  test "row security is enabled, never forced":
    # `force` would apply the policies to the table owner too, which breaks
    # migrations, seeds, the owner-run tools and every backup path.
    var forced: seq[string] = @[]
    for table in tenantTables(db):
      if table.forced:
        forced.add(table.qualified)
    checkpoint(forced.join(", "))
    check forced.len == 0

  test "no table outside the tenant set has row security on":
    var tenant: seq[string] = @[]
    for table in tenantTables(db):
      tenant.add(table.qualified)
    var unexpected: seq[string] = @[]
    for table in tablesWithRls(db):
      if table notin tenant:
        unexpected.add(table)
    checkpoint(unexpected.join(", "))
    check unexpected.len == 0

  test "every view with a tenant column runs with the invoker's rights":
    # Derived from `pg_class`, like the table half: a second view over a tenant
    # table cannot ship without this option and pass unseen. A view that runs as
    # its owner keeps serving every community's rows beside a complete policy
    # set, so this is the one read the table assertions cannot see.
    let views = tenantViews(db)
    checkpoint("views carrying community_id: " & views.join(", "))
    check views.len > 0
    var problems: seq[string] = @[]
    for view in views:
      let problem = viewRunsAsInvoker(db, view)
      if problem.len > 0:
        problems.add(view & ": " & problem)
    checkpoint(problems.join("\n"))
    check problems.len == 0
    check "session.game_results" in views

  test "account.audit admits a NULL community for the application role":
    # A platform-level action and a refused login have no community to name, and
    # a strict equality would make the refusal handler raise instead of writing
    # the audit row.
    let qual = auditAppQual(db)
    checkpoint(qual)
    check qual.len > 0
    check qual.contains("community_id IS NULL")

  test "account.audit gives the prune role exactly one policy":
    # The retention timer deletes by age across every community and holds
    # `select, delete` on this table only, so one unrestricted policy scoped to
    # that role is the whole grant.
    check policyCount(db, "account.audit", "bm2_audit_prune") == 1
    check policyCount(db, "account.audit", "bm2_app") == 1

  test "the prune role has no policy on any other tenant table":
    # The role may empty the audit log and nothing else. A policy that named it
    # on a tenant table would hand the timer a cross-tenant read of the product.
    var leaked: seq[string] = @[]
    for table in tenantTables(db):
      if table.qualified == "account.audit":
        continue
      if policyCount(db, table.qualified, "bm2_audit_prune") > 0:
        leaked.add(table.qualified)
    checkpoint(leaked.join(", "))
    check leaked.len == 0

  test "the cross-tenant read functions are safe DEFINER functions":
    for signature in definerFunctions:
      let problem = definerFunctionProblem(db, signature)
      checkpoint(signature & ": " & (if problem.len == 0: "ok" else: problem))
      check problem.len == 0

  test "the definer function set is exactly the three reviewed signatures":
    # A fourth SECURITY DEFINER function is a cross-tenant read nobody reviewed.
    # Asserting the set rather than each member is what catches it: adding one
    # to the migration without adding it here fails, on purpose.
    let actual = actualDefinerFunctions(db)
    checkpoint("SECURITY DEFINER functions: " & actual.join(", "))
    for expected in definerFunctions:
      check expected in actual
    var unexpected: seq[string] = @[]
    for signature in actual:
      # The append-only audit trigger is SECURITY DEFINER-like in effect but is
      # a trigger function, not a read the application calls; it is excluded by
      # name so the set below stays the three reviewed reads.
      if signature notin definerFunctions and
         signature != "account.audit_append_only()":
        unexpected.add(signature)
    checkpoint("unreviewed: " & unexpected.join(", "))
    check unexpected.len == 0

  test "the tenant predicate reads the GUC and fails closed when it is unset":
    # The predicate is the one place a fail-open bug would leak silently, so it
    # is read back from the database rather than trusted from the file. Every
    # call runs in one transaction: `set_config(..., true)` is
    # transaction-local, so the unset case has to be observable in the same
    # transaction that sets it.
    var unsetIsNull, emptyIsNull: bool
    var setValue: string
    db.tx(proc(conn: DbConn) =
      let unset = conn.queryOne(
        "select session.tenant_id() is null as unset_is_null")
      unsetIsNull = unset.isSome and unset.get.getBool("unset_is_null")

      discard conn.query("select set_config('majadu.community_id', $1, true)",
        @[textParam("11111111-1111-4111-8111-111111111111")])
      let setRow = conn.queryOne("select coalesce(session.tenant_id()::text, '') as id")
      if setRow.isSome:
        setValue = setRow.get.get("id")

      # The empty string is what the facade writes for an unscoped call, so it
      # must be NULL, not a cast error and not a value that matches nothing but
      # is not NULL.
      discard conn.query("select set_config('majadu.community_id', '', true)")
      let emptyRow = conn.queryOne(
        "select session.tenant_id() is null as empty_is_null")
      emptyIsNull = emptyRow.isSome and emptyRow.get.getBool("empty_is_null"))

    check unsetIsNull
    check setValue == "11111111-1111-4111-8111-111111111111"
    check emptyIsNull

  db.close()
