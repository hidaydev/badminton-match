# Tenancy and row level security: options for DB-16

Decision input for Team B, wave 6. Documentation only: no SQL file, no code
change, no migration, no register status touched. Every number below was
measured on this tree at `fb23272` (integration, migration head `0054`) or read
from a named file; anything I could not check is listed in §1.4.

Register finding, as written:

> **DB-16** no RLS and no tenant-scoped views; decision recorded, fix not built.

ADR-018 (`docs/decisions.md:488-517`) already records the deferral and names its
reopener. This paper is the input for deciding whether to reopen it now.

## 1. The tenancy shape the code and migrations actually express

### 1.1 The tenant column

Measured read-only on a local database at head `0054`
(`information_schema` + `pg_class`): **43 tables and 1 view in 10 schemas**
(`account`, `achievement`, `auth`, `community`, `import`, `platform`, `player`,
`rating`, `session`, `tournament`).

**31 tables carry `community_id`.** Thirty are `not null`; `account.audit` is
nullable because a platform-level action (login, owner action, refused request
with no community) has no community to name.

| Schema | Tables with `community_id` | Created by |
|---|---|---|
| `session` | `sessions`, `courts`, `games`, `game_sets`, `game_skips`, `participants`, `links` | `0001_core.sql`, `0010_session_participants.sql`, `0017_game_skips.sql`, `0029_scoring_presets.sql` |
| `player` | `players`, `aliases`, `claims`, `merge_log` | `0001_core.sql`, `0009_player_alias.sql` |
| `rating` | `events`, `player_state`, `snapshots`, `sources`, `levels` | `0002_rating.sql`, `0013_rating_sources.sql`, `0020_rating_levels.sql` |
| `tournament` | `tournaments`, `pairs`, `groups`, `matches`, `teams`, `team_players`, `team_matches`, `team_partai` | `0003_tournament.sql`, `0012_tournament_formats.sql` |
| `community` | `membership`, `invite`, `join_request`, `settings` | `0005_community.sql` |
| `achievement` | `earned` | `0002_rating.sql` |
| `account` | `audit` (nullable) | `0004_platform.sql` |
| `import` | `row_map` | `0015_import.sql` |

**12 tables do not carry it**, and none of them is an oversight:

| Table | Why it is global |
|---|---|
| `platform.community` | the tenant root itself; its `id` *is* the tenant |
| `platform.user` | a person belongs to several communities |
| `platform.config`, `platform.config_version` | platform defaults; per-community overrides live in `community.settings` |
| `platform.cutover_state`, `platform.outbox`, `platform.idempotency_keys`, `platform.ws_ticket`, `platform.ops_token` | process/operator state, keyed by user or request |
| `account.sessions`, `auth.oauth_flows` | a login exists before a community is chosen |
| `achievement.definitions` | the badge catalogue is product-wide, joined by key |

The **view** `session.game_results` (`0029_scoring_presets.sql:58`) carries
`community_id` and is the only relation of that kind in the tree.

So the model is: many communities per database, one tenant root
(`platform.community`, `0001_core.sql`), a person joins a community through
`community.membership` (`0005_community.sql`), and every community-owned row
names the community it belongs to.

### 1.2 What the database enforces, and what it does not

Measured on the same database at head `0054`:

- **No RLS anywhere**: `pg_class` reports `relrowsecurity` on 0 tables, and there
  are 0 policies. No tenant-scoped schema either.
- **Structural integrity is strong**: 42 of 59 foreign keys include
  `community_id`, so a child row cannot point at a parent in another community,
  and 20 of 67 primary-key/unique constraints lead with `community_id`, so the
  lookup a policy would use is already the indexed path. Examples:
  `0010_session_participants.sql:14-17`, `0003_tournament.sql:30-38`.
- **The view is an owner-rights door**: `session.game_results` has no
  `security_invoker` option, so a query through it runs with the privileges of
  its owner (`bm2_owner`, the migration role). Under RLS on the base tables it
  would keep serving rows unless it is rebuilt with
  `with (security_invoker = true)` (PostgreSQL 15+, and this cluster is 18.6).
- **There is already one GUC-based guard in the tree**: `0049_audit_append_only.sql`
  rejects `update`/`delete` on `account.audit` unless
  `current_setting('majadu.audit_maintenance', true) = 'on'`, which
  `modules/platform/audit_retention.nim:41` sets for one transaction. It is a
  working template for the policy mechanics, and it is the shape that a
  half-applied RLS rollout would imitate.
- **Roles** (`ops/db/roles.sql`, `db/migrations/0032_default_grants.sql`):
  `bm2_owner` owns the schema and runs migrations and operator tools;
  `bm2_app` has `select/insert/update/delete` by grant and by default privilege;
  `bm2_etl` reads and writes `import.*`; `bm2_audit_prune` may only see and
  delete `account.audit`. The API connects as **`bm2_app`**, not the owner
  (`ops/env/prod.env.example`, `ops/env/rc.env.example`), so `enable row level
  security` would bind the API without `force row level security`, and the owner
  and every tool would keep bypassing it.

### 1.3 Where the application filters today

- **One door produces the context.** `apps/api/src/community_context.nim`
  (40 lines) turns a slug plus the caller's membership row into
  `CommunityContext`; nothing else constructs one. Its query joins
  `platform.community` to `community.membership`, which is why those two tables
  are the first thing an RLS rollout breaks (§2a).
- **One gate applies it.** `apps/api/src/app.nim:827` (`scoped`) is the shared
  preamble of every `/c/{slug}/...` route; the dispatcher calls it in eight
  places, and `decide` (`app.nim:584-590`) resolves membership before the access
  check so a foreign slug answers 404 rather than confirming it exists. The
  contract has 76 operations (`packages/contracts/openapi/CONTRACT.sha256:7`).
- **The statements scope themselves.** In non-test code, 340 SQL literals name a
  domain table and 328 of them mention `community_id`. The remainder are string
  concatenations (for example `modules/session/schedule.nim:143`, where
  `where community_id = $1` sits in the second fragment) or platform-level JSON,
  not unscoped queries.
- **A static guard already exists.** `tools/archcheck/rules.nim:4` scans every
  statement in `apps/`, `modules/` and `tools/` that names
  `session.`, `player.`, `rating.`, `tournament.`, `community.` or `achievement.`
  and requires `community_id` at the same query level.
  `tools/archcheck/allowlist_community.txt` holds 14 by-design exemptions (share
  code resolution, invite lookup, the community directory, the badge catalogue,
  the operator tools), each with a written reason.
- **The guard is currently red for an unrelated reason on this tree**:
  `archcheck` reports two `use clock.utcNow(), not now()` violations in
  `tools/shelltests/tests/docs_check_test.nim:49` and `:103` (a shelltest
  fixture, not a tenancy statement). Until that is fixed, "the scoping guard
  runs in CI" is true of the rule and not of the gate.

### 1.4 What I could not prove

- **How many communities a production database holds.** I have no host access
  for this task. Local evidence: `bm2_dev` has 34 communities, a fixture database
  at head has 6, and the imported copy (`bm2_explore`) has 1. The schema and the
  routes (`/c/{slug}/...`) are built for many per deployment, and no migration
  assumes one.
- **That no dynamic or generated statement escapes the scan.** The static scan
  reads Nim source; a statement assembled at runtime from a variable would pass
  it. I did not find one, and I did not prove absence exhaustively.
- **The register's own number.** DB-16 says `bm2_app` has grants on "172 tables
  across ten schemas". On this tree the ten schemas hold 43 tables. The 172
  probably counted `role_table_grants` rows or a database that also carried the
  v1 archive; I did not reproduce it, and I did not correct the register.
- **`docs/handbook/data-model.md` is stale at its header** (it says migrations
  `0001`–`0048`; the tree is at `0054`). Its content on tenancy matches what I
  measured.

## 2. Three options

### (a) Full RLS with a per-request GUC

**Migrations.** 30 of the 31 community tables get one policy each (a single
`for all using (…) with check (…)`), plus the exception list below. All of it is DDL in one
transaction per file; on a 13–15 MB database (`bm2_next` 13 MB, `bm2_rc` 15 MB,
the 2026-11-10 host read in the audit register §8) `alter table` takes its
`ACCESS EXCLUSIVE` lock
for milliseconds, so the migration itself is cheap and `dbtools`' 5 s
`lock_timeout` is not at risk. The cost is not the migration; it is what the
policies must not break:

- **The door.** `platform.community` and `community.membership` are read by
  `loadCommunity` *before* any context exists. A policy keyed on the community id
  turns every login and every `/c/{slug}` request into zero rows, and it cannot
  work even in principle: the lookup is by slug, so the row that names the
  community is the one the GUC would have to be set from. Either those two
  tables stay without RLS (the scan remains their guard), or the session carries
  a second GUC naming the slug, which is a second piece of request state to get
  right. The simplest correct form is: no RLS on those two, RLS everywhere else.
- **The view.** `session.game_results` must become `security_invoker` first, or
  it is a hole in an otherwise complete policy set. Rebuilding a view is a
  `create or replace`, no data rewrite.
- **The owner.** Tools and migrations run as `bm2_owner`, which bypasses RLS
  unless `force row level security` is set. That bypass is wanted for
  `tools/import`, `tools/ranksnapshot`, `share/rotateKeys` and the audit prune;
  `force` would demand a bypass mechanism for them instead. Recommendation if
  this option is taken: `enable` without `force`, and treat the owner DSN as the
  privileged credential it already is.
- **Upserts.** There are 41 `insert … on conflict` statements in non-test Nim
  code and 8 in SQL. Under RLS the conflict target must be visible to the
  writer; a row invisible under the `using` clause makes `do update` a no-op or
  an error depending on the command. Every one of these needs to run inside a
  request whose GUC is set, which is what the connection work below provides —
  but it is the class of statement most likely to surface a policy mistake.
- **`account.audit`.** A nullable `community_id` means the policy must also
  admit platform-level rows, or the deny-audit path
  (`apps/api/src/app.nim:594`) starts raising inside a refusal handler.
- **`bm2_etl`.** The cutover loader writes `import.row_map` and, with the
  `primary`/`secondary` mode, community-scoped tables. It would need the GUC set
  from the community it was told to import, or a policy exemption.

**Connection handling.** This is smaller than ADR-018 assumed. Every pooled
statement goes through one function, `withConn`
(`shared/platform-lib/db/db.nim:543`), and `boundTo` (`:552`) already gives a
facade over a connection a caller holds inside a transaction. A
`Db.scoped(communityId)` facade that issues
`select set_config('majadu.community_id', $1, false)` once at checkout and clears
it on release is roughly twenty lines in that file, and `scoped()` in
`app.nim:827` is the one place that would build it per request. Two shapes:

- *Per statement*: set the GUC on every checkout. Correct, and costs one extra
  round trip per statement (2 instead of 1) because `set_config` cannot be
  prepended to an arbitrary statement without parsing it.
- *Per request*: pin one connection for the request (the ADR's own reopener).
  One `set_config` per request, but a connection is held for the whole request,
  and the pool is `threads + 2` (`apps/api/src/main.nim:110-118`), so the
  in-flight request count is the connection ceiling.

**What breaks if a policy is wrong.** Two very different failures: a `using`
clause that is too wide leaks another community's rows silently; a `using`
clause that is too narrow, or a missing GUC, returns zero rows and reads like an
empty database. The first is the one that matters, and it is invisible without a
test that has two communities in one database and asserts the cross reads are
empty. Writing a policy is easy; noticing it is wrong is not.

**Operational cost on the single cluster.** Policies live per database, so
`bm2_next` and `bm2_rc` are changed separately, and a mistake reaches RC before
production only if the rollout order is RC first. There is no cross-database
query anywhere in the tree, so RLS does not interact with the shared instance
beyond the connection count above. At this size (13–15 MB, and a handful of communities on any
database I could count) policy evaluation is not a measurable performance concern, and the
predicate the policies use is already indexed (`community_id` leads 20 unique
constraints).

### (b) Tenant-scoped views and a restricted role

**Shape.** A `tenant` schema holding one view per community-owned table
(`select … where community_id = current_setting('majadu.community_id')::uuid`),
`bm2_app` granted only on those views, base tables revoked. Every statement then
reads `tenant.sessions` instead of `session.sessions`.

**Migrations.** 31 views plus a grant/revoke migration, no policy per command.

**Cost, honestly.** The schema cannot shadow a qualified name, so this is a
**rewrite of 328 statements** (340 domain-table literals) across
`modules/`, `apps/` and `tools/`, with the 41 upserts as the obstacle:
`insert … on conflict` through a view needs the view to be auto-updatable and
the conflict target to be inferable; where it is not, the statement becomes an
explicit update-then-insert or an `instead of` trigger per table. The rewrite
fails closed (a missed statement gets `permission denied`, not a leak), which is
the safety advantage over (a), but the edit surface is ten times larger and it is
mechanical work that touches every read path in the product.

**Connection handling.** Identical to (a): the view also needs the GUC, so the
same `withConn`/`scoped` change is required. (b) does not avoid the connection
work; it only trades 31 policies for 31 views and a large rewrite.

**Operational cost.** Same per-database rollout as (a). One extra moving part:
the `tenant` views become the only interface the app may use, so any future
migration that alters a base table must also keep its view in step — a new
column is invisible until the view is rebuilt, which is the failure mode `0029`
already produced once with grants (`0032_default_grants.sql` records it).

### (c) Status quo plus a scoping test

**Shape.** Keep the schema as it is. Make the existing static guard green, and
add the one dynamic test the finding actually lacks: a fixture with two
communities in one database, where every `/c/{slug}/...` read for community A is
called with a community-B id and must answer 404 or an empty list.

**Migrations.** None. No head, no checksum, no connection handling change.

**What it costs.** One test fixture plus the fix for the two `now()` hits in
`docs_check_test.nim`, both in the QA/architecture stream's area. Days, not
weeks, and no production risk.

**What it does not buy.** The defence stays static: a statement assembled at
runtime, or a new route that queries by a globally unique `session_id` alone,
still returns another community's row. `apps/api/src/app.nim` already has 103
`application.db` references, and the scan is the only thing between them and a
cross-tenant read.

## 3. The decision that gates this

**RLS is not required for physical environment separation; it is required only if
one database serves more than one community in production.**

The premise in the brief needs one correction: `bm2_next` and `bm2_rc` separate
*environments*, not tenants. Each database holds many communities by design —
`platform.community` is a table, the routes are `/c/{slug}/...`, and a local
development database holds 34 communities while a fixture database holds 6. The
question is therefore not "single-tenant-per-database" but:

> Will any production deployment ever serve a second community from the same
> database?

- **No, and it is a product rule** (one club per deployment, the slug is
  cosmetic): option (c) is correct and defensible, and ADR-018 should be amended
  to record *that* reason instead of the connection-pool one, which I showed is
  smaller than it reads.
- **Yes, or undecided**: (c) now, (a) before the second community is created. The
  two-community test is the prerequisite for either, and the policy work needs the
  request context that (a) describes.

I would not take (b) in any branch of that decision: it pays the connection cost
of (a), leaves the write path to be guarded separately, and adds a view
maintenance obligation on 31 relations for a smaller policy count.

## 4. Recommendation and the first step

**Recommendation: option (c) for this release, with two conditions** — `archcheck`
is green in CI (including the two unrelated `now()` violations), and the
two-community test exists and fails when a predicate is removed from one read
path. Keep RLS on the table, not in the release.

The reason is not that the risk is small; it is that the risk today is
concentrated in one place. Every community-scoped read reaches the database
through `CommunityContext`, produced by one 40-line function and consumed by one
gate, and 328 of 340 domain statements carry the predicate. The remaining
exposure is the next handler, and a dynamic test with two communities in one
database is the cheapest way to catch it. RLS would be the stronger second line,
and its plumbing is genuinely one function, but a policy set that is wrong in the
narrow direction turns every list into an empty page and one that is wrong in the
wide direction is silent. Neither is acceptable on a release branch without the
test that would detect it, so the test comes first either way.

**First step, one to two days, no schema change:** the two-community fixture,
plus the two `now()` fixes in `tools/shelltests/tests/docs_check_test.nim` so the
static guard is green and can be cited as a gate. That is the smallest artefact
that proves the claim (c) rests on: that the isolation holds today and that a
removed predicate is caught.

**Mechanism (implemented 2026-11-11):** the condition is no longer prose. The
guard is `modules/community/tenancy.nim`:

| Part | What it does |
|---|---|
| `communityCount(db)` | `select count(*) from platform.community` |
| `singleCommunityViolation(communities, environment)` | returns the refusal message, or `""`; only `environment = "prod"` is constrained |
| `assertSingleCommunity(db, environment)` | raises `ValueError` with that message |

`bootHandler` (`apps/api/src/main.nim`) calls `assertSingleCommunity(database,
getEnv("MAJADU_ENV"))` after the pool opens and before the handler is installed,
so a production process refuses to serve a database that holds more than one
community, and `main` turns the `ValueError` into `refuseStartup` with the
reason on stderr. The message names the count, ADR-018 and this document, so the
operator sees what to do rather than a bare assertion.

Why production only: a development or test database holds many communities by
design (34 on the development cluster when this was written), and a guard that
ran there would refuse the work it is meant to protect. Why the boot rather than
a migration: the community count is data, not schema, and a migration cannot
refuse a row added later; the boot is the last point that can refuse before
requests are served.

What it does not do, stated so nobody reads it as more than it is:

- It guards the API process. A tool or a `psql` session running as `bm2_owner`
  can still insert the second community; the next API restart refuses to start
  until it is moved, which is the loud failure the condition asks for.
- It does not protect a running process: a second community inserted while the
  API is up is served until the next restart. RLS is the control for that, and
  this is why the assertion is a backstop and not a substitute.
- It is not evaluated by `./task check` as a database fact; the rule half is
  unit-tested (`modules/community/tests/tenancy_test.nim`) and the door half is
  integration-tested with two communities in one database
  (`apps/api/tests/integration/community_context_test.nim`).

Lifting it: the assertion is deleted in the release that ships RLS and the
two-community isolation test as a gate, which is the same release ADR-018 names.

**If the decision flips to RLS**, the first step there proves it without
committing: a spike branch (not merged) that sets the GUC from `scoped()`, enables
RLS on **`player.players` and `session.sessions` only**, runs the whole
integration suite, and records how many of the 340 statements fail and why. That
answers "does the request-context plumbing work at all" for two tables. The rough
sequence after a green spike:

| Migration | Contents |
|---|---|
| `0055` | `session.tenant_id()` helper that raises a named error when the GUC is unset; `session.game_results` rebuilt with `security_invoker = true` |
| `0056` | RLS + policy on the three hottest tables (`player.players`, `session.sessions`, `rating.player_state`), `enable` only |
| `0057` | RLS + policy on the rest of `session.*` and `player.*` |
| `0058` | RLS + policy on `rating.*`, `tournament.*`, `achievement.earned`, `community.settings`/`invite`/`join_request` (not `membership`, the door reads it first); `account.audit` with the platform-row clause |
| `0059` | `import.row_map` policy and the ETL GUC, then the two-community test promoted from fixture to gate |

Each file is one transaction, so a failed batch leaves the previous head intact,
and every batch is followed by the full integration suite before the next.

**In one line: take (c) now — a green static guard plus a two-community test —
and keep (a) as the plan for the release that puts a second community in one
production database; (b) is not worth its rewrite.**
