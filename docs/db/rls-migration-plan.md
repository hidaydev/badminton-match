# RLS migration plan: one database, many communities

Plan for the release that turns option (a) of `docs/db/rls-tenancy-options.md`
into the database-side tenancy guard. Documentation only: no migration file, no
schema change, no code change, nothing run against any database.

Every number below was counted in this checkout, not copied from the options
paper. The source is `db/migrations/*.sql` and the Nim tree at `3a0aa142` plus
the 18 uncommitted files of the in-progress multi-community change (which
deletes `modules/community/tenancy.nim` and its boot/create guard). Counts come
from parsing the SQL files and from `ripgrep` over executable lines with comment
lines stripped; **no live database was read and none was written.** Where a
number here disagrees with the options paper, this document says so and gives
the method that produced it.

`HEAD` migration is `0060_drop_removed_config_keys.sql`. The next free number is
`0061`.

---

## 0. The decision, in four lines

**Options.** (a) row level security with a per-request-or-per-statement tenant
GUC, over the existing connection facade; (b) tenant-scoped views and a
restricted role; (c) status quo: keep the app-level guard and the contract-walked
isolation matrix, add nothing.

**Picked.** (a), shipped as a **two-step deploy**: first a release that carries
the connection plumbing and no schema change, then a release one full deploy
later that enables the policies. Option (b) is refused again for the reason the
options paper gives (328 statements to rewrite, plus the same connection work);
it also buys nothing on the write path.

**Why.** Fredi enabled multi-community in one production database on
2026-11-23, which is exactly the condition ADR-018 named as the reopener. The
app-level guards came off in the same change, so tenancy is now held only by the
route gate and a static statement scan. A statement that never passes through
`scoped()` has no tenant guard left, and a scoped read that loses its predicate
still returns 200 with another community's rows.

**What would reverse it.** Three things, each concrete:

- The product rule flips back to one community per deployment. Then RLS is
  unnecessary and the isolation matrix is enough, as ADR-018 first recorded.
- A planned feature needs to read across tenants on one connection (a
  cross-community leaderboard or a consolidated report). Then a bypass role and
  an explicit allowlist of cross-tenant statements are part of the design, and
  the policy set changes shape.
- The parity probe (§6.3) shows `bm2_app` request latency past the SLO after
  step 2, and per-request pinning plus a larger pool does not fix it inside the
  512 MB container. Then the connection half is re-designed before the policies
  reach production.

---

## 1. The policy set

### 1.1 What the schema holds, counted

43 base tables and 1 view in 10 schemas (`account`, `achievement`, `auth`,
`community`, `import`, `platform`, `player`, `rating`, `session`, `tournament`).
The migrations contain 45 `create table` statements; two are dropped again
(`rating.deltas`, `platform.import_row_map`), so 43 live.

**31 tables carry `community_id`.** 30 of them declare it `not null`;
`account.audit` declares it nullable (`0004_platform.sql:106`, `community_id
uuid,`) because a platform-level action has no community to name.
`community.settings` is `not null` by primary key on the column.

| Schema | Tenant tables | Names |
|---|---|---|
| `session` | 7 | `sessions`, `courts`, `games`, `game_sets`, `game_skips`, `participants`, `links` |
| `tournament` | 8 | `tournaments`, `pairs`, `groups`, `matches`, `teams`, `team_players`, `team_matches`, `team_partai` |
| `rating` | 5 | `events`, `player_state`, `snapshots`, `sources`, `levels` |
| `player` | 4 | `players`, `aliases`, `claims`, `merge_log` |
| `community` | 4 | `invite`, `join_request`, `membership`, `settings` |
| `achievement` | 1 | `earned` |
| `import` | 1 | `row_map` |
| `account` | 1 | `audit` (nullable) |

The 12 tables without it: `platform.community` (the tenant root), `platform.user`,
`platform.config`, `platform.config_version`, `platform.cutover_state`,
`platform.outbox`, `platform.idempotency_keys`, `platform.ws_ticket`,
`platform.ops_token`, `account.sessions`, `auth.oauth_flows`,
`achievement.definitions`.

Also counted: **65 `references` clauses**, of which **47 involve `community_id`**
(33 are composite `foreign key (community_id, …) references … (community_id, …)`
pairs and 14 are an inline `community_id uuid … references …`). The rest point at
parents that are per-community rows reached by plain uuid. On the 31 tenant
tables there are **37 primary-key/unique constraints: 26 lead with
`community_id`, 11 omit it entirely, and none has it anywhere but first** (§3.2).

**No row security exists anywhere today:** 0 occurrences of `enable row level
security`, `create policy`, `relrowsecurity`, `security_invoker` or `security
definer` in `db/`, `ops/db/`, `apps/`, `modules/` and `tools/` (test files
excluded).

### 1.2 Which relations get a policy

**30 of the 31 tenant tables get one. `community.membership` does not.
`platform.community` and `platform.user` are not tenants and get none.**

The standard policy, one per table, identical on 29 of them:

```sql
alter table <table> enable row level security;          -- enable, never force
create policy tenant_isolation on <table>
  for all to bm2_app
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());
```

with

```sql
create function session.tenant_id() returns uuid
language sql stable as $$
  select nullif(current_setting('majadu.community_id', true), '')::uuid
$$;
```

`current_setting(..., true)` returns NULL when unset; `nullif` turns the empty
string into NULL; `community_id = NULL` is NULL, which a `using`/`with check`
treats as false. **A missing GUC therefore returns zero rows and a refused
`with check`, never another tenant's row.** This is deliberate: a fail-open
predicate is the one bug that would leak silently.

`to bm2_app` rather than `to public`: `bm2_owner`, `bm2_etl` and
`bm2_audit_prune` are then governed by their own grants and their own policies,
not by the application's. `enable` and not `force`, so `bm2_owner` keeps
bypassing: migrations, `dbtools seed`, `ownerseed`, and the operator commands of
§3.7 that are run with the owner DSN. That bypass is the privileged credential it
already is; forcing it would demand a second bypass mechanism instead. `bm2_etl`
and `bm2_audit_prune` do **not** bypass — they are ordinary roles here — which is
why §3.4 gives the loader a scoped facade and §3.3 gives the prune role its own
policy.

**29 of the 30 use the standard policy as written; `account.audit` is the only
one whose policy differs.** Two of those 29 additionally get a `security definer`
read path, which is a change to the caller, not to the policy:

| Table | Policy | What else changes |
|---|---|---|
| `account.audit` | `using (community_id is null or community_id = session.tenant_id())` and the same in `with check`, plus a second policy `audit_prune_all for all to bm2_audit_prune using (true)` | nothing; the nullable column is the whole reason (§3.3) |
| `session.links`, `community.invite` | **standard**, unchanged | the lookups that start from a secret (share code, invite token, email) go through a `security definer` resolver (§1.3); every other statement stays policy-governed |

`session.links` is worth spelling out because it looks like an exception and is
not: only the lookup that starts from a secret goes around the policy. Everything
a signed-in reader does with a link — revoke, list, re-key — is still
`community_id`-filtered.

The remaining 27 are uniform, `community.join_request` and `community.settings`
among them: every one is reachable only through a slug that resolves to a
community id first (§1.3), so they are ordinary `community_id` policies.

### 1.3 The doors: what has to read a tenant table before a context exists

The options paper names two: `platform.community` and `community.membership`,
read by `loadCommunity` (`apps/api/src/community_context.nim:19-40`, the join at
`:24-27`, then `currentSettings` at `:39`) before any community id exists. Both
confirmed against the code: `platform.community` is a root table with no policy,
and `community.membership` stays without one, because the query that produces
the context joins exactly those two and is keyed by slug plus the caller's own
`user_id`. Giving `membership` a policy keyed on the community id makes every
login and every `/c/{slug}` request zero rows, and it cannot work even in
principle: the row that names the community is the row the GUC would have to be
set from.

Walking the tree for the same pattern finds **three more pre-context reads** the
paper does not list, all of which a naive policy set would break:

| Reader | Statement | Why it has no context yet |
|---|---|---|
| `modules/share/store.nim:122-134` (`shareLookupFrom`), used by `resolve` at `:149-161`; called from `apps/api/src/app.nim:1255, 2781, 2996, 3009, 3075` | `session.links l join session.sessions s join platform.community c` by `code_hash` | the code *is* the credential; the row names the community. Five call sites in `app.nim`, covering `/s/{code}`, its rankings, the ws ticket and the ws handshake. |
| `modules/community/infrastructure/invite.nim:42-61` (`lookup`), `:63-84` (`acceptPendingForEmail`) | `community.invite` by `token_hash` / by `email_hash` | an invite token or an address is presented before a community is chosen; these run at login |
| `modules/session/application/detail.nim:205-212` (`inCommunitySlug`) | `session.sessions s join platform.community c ... where s.id = $1 and c.slug = $2` | the ws handshake has a ticket and a slug, no context |

The fix for each is one of two shapes, and the plan uses both:

- **Resolve, then scope.** `platform.community` has no policy, so reading it by
  slug or by id keeps working with no GUC. Once the id is in hand, everything
  after it runs on a scoped facade. That covers `inCommunitySlug` (read the
  community id by slug, then a scoped read of `session.sessions`) and
  `requestJoin`'s settings lookup (`app.nim:1584-1604`, the `left join
  community.settings` by slug: split into a root read and a scoped read, or wrap
  it as a `security definer` function like the two below).
- **One definer function per secret-keyed lookup.** For `session.links` and
  `community.invite` the tenant genuinely is not known until the row is read, so
  the single resolver statement becomes a `security definer` function owned by
  `bm2_owner` with a pinned `search_path`, returning only the columns the caller
  needs (`link_id, community_id, session_id, key_id, code_enc` for the share
  path; `community_id, role, email_hash, accepted_at, expires_at` for the invite
  path). The rules of §5.9 of the PostgreSQL manual apply: the function runs as
  the owner, so it bypasses RLS on purpose, and its body is one indexed lookup
  by an unguessable hash. Everything the caller does *after* it runs under a
  scoped facade built from the returned community id.

The alternative — leaving `session.links` and `community.invite` without a
policy — is cheaper by two functions and loses the guarantee on exactly the two
tables whose rows are reachable by a URL. It is named here so the choice is
recorded, not because it is close.

### 1.4 The view

`session.game_results` (`db/migrations/0029_scoring_presets.sql:58-99`) is the
only view in the tree and carries `community_id`. It has no `security_invoker`
option, so a query through it runs with the owner's privileges and would keep
serving every community's rows beside a complete policy set.

Read by 9 non-test statements in 6 files: `modules/rating/read.nim` (2),
`modules/rating/projection.nim` (1), `modules/rating/infrastructure/ingest.nim`
(1), `modules/achievement/infrastructure/backfill.nim` (1),
`modules/session/standings.nim` (1), `modules/session/application/detail.nim` (3).
Grants: `bm2_app` by default privilege (`0032_default_grants.sql`), `bm2_etl` by
`0034_etl_grants.sql` (`grant select on session.game_results to bm2_etl`). Both
roles also hold `select` on the base tables the view reads
(`session.games`, `session.sessions`, `session.game_sets`), so switching the view
to invoker rights does not break either path.

The change is one line and must land in the same file as the policies, before
them:

```sql
alter view session.game_results set (security_invoker = true);
```

`alter view ... set (...)` sets the reloption without restating the query, so
the view body cannot drift from `0029` while it is being hardened. Verify it took
by reading `pg_class.reloptions` in the gate test (§5).

---

## 2. The connection change

### 2.1 Where it goes, measured

One function hands out every pooled connection: `withConn`
(`shared/platform-lib/db/db.nim:594-601`). Everything above it is a thin
wrapper — `query` (`:611`), `queryOne` (`:614`), `execUpdate` (`:617`), `read`
(`:620`), `txRet` (`:628`), `tx` (`:694`) — and `boundTo` (`:603-609`) builds a
facade over a connection the caller already holds inside a transaction
(`pinned`, field at `:38`), which skips the pool entirely.

So the tenant GUC has exactly one insertion point, and a facade that carries it
is a copy of the `boundTo` shape: `Db.scoped(communityId)` returns
`Db(size: db.size, scopedCommunity: communityId)` with no pin, and `withConn`
issues one extra statement at checkout when the facade carries a community.

### 2.2 Per statement, not per request

| | Per statement (set at every checkout) | Per request (pin one connection) |
|---|---|---|
| Round trips | 2 per statement | 1 per request |
| Connections held | only for the statement | one per in-flight request |
| Pool arithmetic | unchanged | see below |
| Failure if the reset is missed | impossible: every checkout overwrites | stale tenant on a reused connection |

The pool is `workers + 2` (`apps/api/src/main.nim:36-47`, `poolSizeFor`), and the
worker count is `max(cores, 1) * 4` (`:23`, `:38-42`). On the host the capacity
statement names — 2 vCPU, 7.4 GB, a 512 MB container (`docs/ops/operations.md:245`)
— that is **8 worker threads and a pool of 10 connections**.

Per-request pinning means each in-flight request holds one connection for its
whole life, so 8 requests occupy 8 of the 10, and the two spares are all that is
left for the nested checkouts the pool exists for: `main.nim:25-29` says outright
that a worker can need a second connection while it already holds one, because a
`tx` body calls a `Db` helper. The tree has 64 `tx`/`txRet` call sites and 36
`auditedWrite` call sites outside tests, so nesting is not rare. A third
concurrent nested checkout then waits out `MAJADU_DB_ACQUIRE_TIMEOUT_MS` (default
5000, `db.nim:60`) and raises `DbPoolTimeout`, which `guarded` maps to 503
`UNAVAILABLE` (`apps/api/src/app.nim:3810-3825`). Per-request pinning converts a
rare condition into a structural one.

**Picked: per statement.** The cost is one extra round trip per statement; the
statement itself runs on a connection whose setting is always the one this call
wrote, and the pool arithmetic does not change, so the 512 MB container does not
need a second look. If latency shows up after step 2, the cheap fix is to raise
`poolHeadroom` and re-measure before switching shapes — not to pin first.

The write must be unconditional, including on unscoped facades:

```nim
discard conn.execUpdate("select set_config('majadu.community_id', $1, false)",
  @[textParam(scopedCommunityOrEmpty)])
```

Setting the empty string and letting `tenant_id()` turn it into NULL is what
makes a leaked session-level value impossible: no checkout inherits the state of
the previous one, so there is no reset path to forget. `set_config(..., true)`
is not usable here: outside an explicit transaction block it has no effect, and
most read paths are a single statement.

Measured scale: `database()` is called at 108 sites in
`apps/api/src/app.nim`; **235 statement calls** (`conn.query`, `conn.queryOne`,
`conn.execUpdate`, `conn.execScript`) sit inside a transaction across 32 non-test
files, the largest being `tools/import/main.nim` (38) and
`modules/player/merge.nim` (32). None of them changes under this design, which is
the point of putting the GUC in `withConn`: 64 `tx`/`txRet` call sites and 36
`auditedWrite` call sites keep their bodies untouched.

### 2.3 The one call site that builds it

`scoped()` — `apps/api/src/app.nim:864`, eight dispatch call sites at `:3470`,
`:3503`, `:3557`, `:3585`, `:3608`, `:3636`, `:3641`, `:3650`. It already
resolves the membership through `decide` (`:593-598`, which calls
`loadCommunity(database(), user.id, slug)`) and returns
`Option[(AuthUser, CommunityContext)]`. It is the only place that knows both the
caller and the community before the handler runs.

The build is one line inside it, after the gate passes:

```nim
setScopedDb(database().scoped(ctx.get.communityId))
```

with `database()` (`:103-112`) returning the scoped facade while one is installed
for the request on this worker thread, and the pool otherwise. That is the same
mechanism the file already relies on for `currentRouteLabel` (`:117`) and
`apps/api/src/server.nim:98-100` for the request id: each connection is served on
a single worker thread, so a `threadvar` cannot leak between requests. Without
it, the alternative is threading a `Db` parameter through 108 call sites and the
modules behind them.

The install must be undone in a `finally` in `route()`
(`apps/api/src/app.nim:3842-3849`), which already wraps the whole request:
a handler that raises must not leave a tenant installed for the next request on
that thread.

Two statements stay on the pool on purpose and keep working because their
tables have no policy: `loadCommunity` (slug → community) and the audit writes
that carry no community (`app.nim:176`, `:185`, `:619`).

---

## 3. Obstacles, counted now

### 3.1 `insert ... on conflict`

**40 occurrences on executable lines in 17 non-test Nim files.** 26 take the
`do update` path, 14 the `do nothing` path. The options paper says 41; I could
not reproduce 41 from this tree — one line in `tools/dbtools/main.nim:221` and
three in `modules/rating/infrastructure/ledger.nim:25` and
`db/migrations/0059`,`0060` are comments, and stripping them leaves 40.

Per file: `tools/import/main.nim` 20, `modules/session/schedule.nim` 3,
`modules/player/store.nim` 2, `modules/community/infrastructure/membership_sql.nim`
2, and one each in `modules/achievement/infrastructure/backfill.nim`,
`apps/api/src/app.nim`, `apps/api/src/config_routes.nim`,
`modules/rating/read.nim`, `modules/rating/infrastructure/ingest.nim`,
`modules/rating/infrastructure/ledger.nim`, `modules/platform/idempotency.nim`,
`modules/tournament/store.nim`, `modules/community/infrastructure/community_store.nim`,
`modules/community/infrastructure/join_request.nim`, `modules/player/claim.nim`,
`tools/ratinglevels/main.nim`, `tools/dbtools/main.nim`.

**9 occurrences in `db/` SQL** across 8 files: `0004_platform.sql:25`,
`0022_rank_streak_ladder.sql:11`, `0028_config_cleanup.sql:22`,
`0029_scoring_presets.sql:110`, `0050_rating_top_band_width.sql:13`,
`0056_court_foreign_keys.sql:76` and `:107`, `db/seeds/achievement_definitions.sql:62`,
`db/seeds/platform_config.sql:86`. The paper says 8. The executable count is 9;
the extra one is `0056`, which has two. (There is a tenth in
`ops/dev/v1/schema.sql:121`, which is the v1 archive and never runs here.)

Only **2** of the 9 touch a tenant table: both are `session.courts` in `0056`,
and both run inside the migration as owner (RLS is not on yet, and the owner
would bypass it anyway), so they are not a risk — they are listed because they
are the two that would be wrong if this file were ever rerun by a non-owner.
`0004`, `0028`, `0029` and `0050` write `platform.config*`,
`0022` writes `achievement.definitions`, and the two seeds write
`achievement.definitions` and `platform.config`.

What changes under RLS, from the manual's own table (§5.9, table 301, and
`CREATE POLICY`):

- `on conflict do nothing` **without** an arbiter is exempt: 4 such statements
  exist, all on tenant tables (`community.join_request` at `join_request.nim:21`,
  `player.claims` at `claim.nim:57`, `session.game_skips` at `schedule.nim:445`
  and `import/main.nim:558`).
- `on conflict` **with** an explicit arbiter, or `do update`, requires `SELECT`
  permission on the relation and checks the proposed row, and the existing row,
  against the SELECT policies. If the existing row is invisible the statement
  **errors** rather than silently skipping. **36 of the 40** statements are on a
  tenant table, and 32 of those name an arbiter. The six on tenant tables whose
  arbiter does not lead with `community_id` are the ones worth walking
  individually:

| File | Arbiters | Table |
|---|---|---|
| `modules/session/schedule.nim:208` | `session_id, player_id` | `session.participants` |
| `tools/import/main.nim:387` | `session_id, player_id` | `session.participants` |
| `modules/tournament/store.nim:688` | `team_match_id, partai_index` | `tournament.team_partai` |
| `tools/import/main.nim:856` | `team_match_id, partai_index` | `tournament.team_partai` |
| `tools/import/main.nim:704` | `tournament_id, group_id, position` | `tournament.groups` |
| `tools/import/main.nim:801` | `team_id, cls` | `tournament.team_players` |

The other 26 tenant statements name `community_id` inside the arbiter, so the
row they are looking for is the row the policy admits by construction. The
remaining 4 of the 40 are not on a tenant table at all: `platform.user` at
`app.nim:769`, `platform.idempotency_keys` at `idempotency.nim:41`,
`platform.community` at `community_store.nim:25`, `dbtools.seed_files` at
`dbtools/main.nim:230`.

The 4 arbiterless `do nothing` statements are worth one more sentence, because
the manual's exemption is narrower than it reads: `INSERT … ON CONFLICT DO
NOTHING` *without* an arbiter spec is exempt from the SELECT-policy check, but
the same statement *with* an arbiter spec (which several callers pass by naming
a constraint) is not. Every one of the four is written without a spec, so they
are exempt as written — and the rule for the release is that no one may add an
arbiter spec to them without re-reading this section.

### 3.2 Primary keys and unique constraints that do not lead with the tenant

On the 31 tenant tables: 37 primary-key/unique constraints, 26 of which lead
with `community_id`; the 11 that omit it entirely are

`session.links (code_hash)`, `session.links` partial `links_one_live (session_id)`,
`session.courts (session_id, court_index)`,
`session.games (session_id, round_no, court_no)`,
`session.participants (session_id, player_id)`,
`session.game_sets (session_id, round_no, court_no, set_no)`,
`player.claims` partial `claims_one_approved (player_id)`,
`community.invite (token_hash)`,
`tournament.groups (tournament_id, group_id, position)`,
`tournament.team_players (team_id, cls)`,
`tournament.team_partai (team_match_id, partai_index)`.

None of them has `community_id` in a later position, so the policy predicate is
never served by the tail of an index — it is either the prefix (the 26) or absent
from the index altogether (the 11).

Each is safe because the id that leads it is itself community-scoped
(`session_id`, `player_id`, `team_id`, `tournament_id` are per-community rows
with composite foreign keys back to a `(community_id, id)` unique), or because
the key is a deliberate global secret (`code_hash`, `token_hash`). They are
listed because they are the constraints that would let one community's insert
collide with another's row, and §3.1 shows what the statement does when it does.

The remaining obstacle in this class is the lookup path: the policy predicate is
`community_id = tenant_id()`, and **none of the 11 carries `community_id` at
all**, so on those tables the predicate is a filter applied after an indexed
lookup keyed on something else (`session_id`, `player_id`, `tournament_id`,
`team_id`, `code_hash`, `token_hash`). That is fine at this data size — the
lookup is still indexed, and the policy predicate is a cheap re-check on the rows
it returns — and it is not fine as a rule for new tables, because a predicate
that no index serves on a large table is a scan.

Two of the 11 are a different shape: `session.links(code_hash)` and
`community.invite(token_hash)` are looked up by a secret with **no** community in
the query at all. Those go through the definer function of §1.3, which reads the
row before any policy applies. The two partial unique indexes
(`links_one_live` on `session_id`, `claims_one_approved` on `player_id`) are only
reached from an already scoped statement, so they stay as they are.

### 3.3 `account.audit` and its nullable community

`db/migrations/0004_platform.sql:101-116`: `community_id uuid,` with no
`not null`. Three write paths leave it NULL: `app.nim:176` and `:185` (the login
refusals, `communityId = ""` → `textOrNull` → NULL), `app.nim:619` (`denyAudit`
for a slug that resolved to nothing), and
`modules/account/infrastructure/lifecycle_store.nim:87` (`account.anonymize`).

A strict `community_id = tenant_id()` policy would make `denyAudit` raise inside
a refusal handler, which `app.nim:625-627` catches but which would leave the
refusal unaudited. The policy must therefore admit `community_id is null` as
written in §1.2. The retention timer is the second exception: it connects as
`bm2_audit_prune` (`ops/env/prod-tools.env.example:47`), which has `select` and
`delete` on this table only (`ops/db/roles.sql:35-38`), and it deletes by
`occurred_at` across every community. Its policy is `using (true)` scoped to
that role, which leaves `bm2_app` untouched.

`ops/db/roles.sql:62-64` already asserts `bm2_app` cannot delete from
`account.audit`; the trigger from `0049_audit_append_only.sql` already rejects
`update`/`delete` unless `majadu.audit_maintenance` is `on` for the transaction.
Those two stay exactly as they are; a policy is a third, independent gate.

One measured detail about the timer that the policy must not break: the append
guard on `0049` is a `before update or delete` trigger on the table, so it fires
for `bm2_audit_prune` too — the timer sets `majadu.audit_maintenance` for its
transaction (`modules/platform/audit_retention.nim:41`) and the delete proceeds.
A `using (true)` policy for that role adds no new condition, and a policy on
`delete` alone would be the wrong shape (the timer also reads the rows it is
about to delete through the `ctid in (select ctid …)` form).

### 3.4 `bm2_etl` and the cutover loader

`0034_etl_grants.sql` gives `bm2_etl` usage on 7 schemas and rights on 29
relations. `tools/import/main.nim` writes with `target.tx` at 12 sites and
carries 20 of the 40 `on conflict` statements. It creates the community first
(`main.nim:100-118`) and then works entirely inside the community id it just
returned.

Under RLS, `bm2_etl` does not bypass (it is not the owner and has no
`bypassrls`), so the loader needs the GUC per community. That is the same
facade: `target.scoped(communityId)` once the id is known, which covers all 12
`tx` sites because they all run after `ensureCommunity`. The alternative — a
`bypassrls` grant on `bm2_etl` — is refused: the loader would then be a
credential that reads every tenant, and it is the one process that writes new
communities' rows from an untrusted dump.

`import.row_map` is a tenant table and gets the standard policy, so the map
writes (`main.nim:130-136`, `:123`) land only under the GUC. That is also what
keeps a rerun of the loader from reading another community's map.

### 3.5 The migration runner applies every pending file in one transaction

`tools/dbtools/main.nim:132-171`: `migrate` opens one `db.tx`, takes
`pg_advisory_xact_lock`, and then loops every pending file inside that same
transaction. The options paper describes each migration as "one transaction, so
a failed batch leaves the previous head intact" — that is true across runs, not
within one, and it changes the rollout: a release's policies are atomic
together, and there is no safe half-applied state to deploy in the middle. So
splitting the policies across `0062`…`0065` only splits them across *releases*;
it does not make a single release resumable.

Practical consequence: **step 2 ships one migration file** (or several files
applied atomically) and is gated as a whole. Batch size then buys nothing and
costs deploys, so the plan does not batch.

### 3.6 The three unattended jobs that sweep every community as `bm2_app`

This is the obstacle with the worst failure mode, and the options paper does not
name it. Three scheduled units connect with `MAJADU_PG_DSN` from
`majadu-tools.env`, which is **`bm2_app`**
(`ops/env/prod-tools.env.example:17`), and each one works across every community
in one process:

| Unit | Tool | Community-scoped work it does |
|---|---|---|
| `majadu-janitor.service` | `janitorcli` | `purgeTargets` has **10 branches, 4 of them on tenant tables** (`session.links` twice, `community.invite` twice), deleting by age across the whole table |
| `majadu-snapshot.service` | `ranksnapshot` | loops `platform.community`, and per community reads `community.settings`, the board (`rating.player_state`, `player.players`, `rating.snapshots`, `rating.events`) and upserts `rating.snapshots` |
| `majadu-ingest.service` | `ratingingest tick` | loops `platform.community`, and per community reads `session.sessions` and writes `rating.events`, `rating.player_state`, `achievement.earned` |

None of them sets a GUC, because none of them has a request. Under the policy set
they do not fail loudly — **they succeed with zero rows**:

- `janitorcli` → `purge` → `purgeBatch` (`modules/platform/janitor.nim:65-82`):
  `delete from <t> where ctid in (select ctid … limit n)` matches nothing, the
  loop sees `deleted < batchSize` and returns, the tool prints
  `{"retentionDays":…,"deleted":0}` and exits 0. The unit is green, the timer
  fires again tomorrow, and expired share links and accepted invites are never
  pruned.
- `ranksnapshot` → `board(...)` returns 0 rows, `writeSnapshot` gets an empty
  `rows` and inserts 0 rows through `unnest` of three empty arrays, so it prints
  `{"communities":N,"rows":0}` and exits 0. Daily snapshots stop, and
  `rating.snapshots` history has a hole nobody can backfill without the board of
  that day.
- `ratingingest tick` → `pendingSessions` reads `session.sessions` and gets 0, so
  no events are written and the board freezes. It prints counts and exits 0.

This is exactly the shape the `eng-data` rule warns about: "a pipeline that ran
fine with zero rows is a failure". The API failing is visible to a person; these
three fail silently, every night, and the damage compounds — ratings stop
advancing, snapshots gap, links accumulate dead rows in the one-live index.

**Fix, and it is not optional.** Each of the three gets the GUC from the loop it
already has, or gains the loop:

- `ranksnapshot` and `ratingingest` already iterate `select id, timezone from
  platform.community`, which has no policy, so each iteration wraps its body in
  `db.scoped(communityId)`.
- `janitor` has no community loop at all; it must gain one
  (`for row in db.query("select id from platform.community")`) and run its tenant
  branches through a scoped facade. The non-tenant branches
  (`auth.oauth_flows`, `platform.idempotency_keys`, `platform.outbox`,
  `account.sessions`, `platform.ops_token`, `platform.ws_ticket`) stay on the
  plain pool. Ordering matters: purge the tenant tables per community, then the
  platform tables once.
- The `majadu-audit-retention` unit is the fourth job against this database and
  is unaffected: it connects as `bm2_audit_prune`
  (`ops/env/prod-tools.env.example:47`), which gets its own `using (true)` policy
  (§3.3).

The alternative — a `bypassrls` grant on `bm2_app` — is refused flatly: it would
give the API process itself cross-tenant read for the sake of three cron jobs.

And the reason this needs a test and not just a code review: every one of the
three exits 0 when it does nothing. The gate in §5 adds a job-level assertion,
because no existing check would notice.

### 3.7 The tools that are run by hand

Nine non-test tools take a DSN with no fallback (`dsnOrFail(program)`, default
`MAJADU_PG_DSN`, `shared/platform-lib/cli.nim:22-27`): `accountlifecycle`,
`dbtools`, `janitorcli`, `opstoken`, `ownerseed`, `ranksnapshot`, `ratingingest`,
`ratinglevels`, `sharekeys`. Which role they run as is whatever the operator
exported. Three of the nine are the unattended jobs of §3.6. The other six are
operator commands, and they fall into two groups that the release has to keep
apart:

**Meant to be the owner, and documented that way.** `dbtools` (deploy runs it
with `MAJADU_OWNER_DSN`, `ops/scripts/deploy-vps.sh:572,580`) and `ownerseed`
(`ops/scripts/cutover.sh:533`). `bm2_owner` bypasses RLS (no `force`), so both
are unaffected with no code change.

**Finished with the owner, but take `MAJADU_PG_DSN`.** `sharekeys`,
`accountlifecycle`, `opstoken` and `ratinglevels`. `task.d/sharekeys.sh` and
`task.d/account.sh` pass the operator's own `MAJADU_PG_DSN` straight through
(`:9-10` in both), and in `majadu-tools.env` that variable is **`bm2_app`**
(`ops/env/prod-tools.env.example:17`). So "run it as the owner" is a step the
operator performs by exporting a different DSN, not a default, and two of these
would go wrong silently:

- `sharekeys rotate` reads `session.links where key_id = $1` across **every**
  community (`modules/share/store.nim:270-309`) and rewrites each row. As the
  owner it is fine; as `bm2_app` it finds no rows, re-encrypts nothing and prints
  `0 link(s)` — a green no-op during a key rotation.
- `accountlifecycle anonymize` fans out over `communitiesOf(userId)`
  (`modules/account/infrastructure/lifecycle_store.nim:13-25`) — a deliberately
  cross-tenant read of `player.claims`, `player.players` and
  `community.membership`. As `bm2_app` it would find no communities and anonymize
  nothing, which is the one failure here that leaves personal data behind while
  reporting success.

`tools/import` is a third case and is already covered by §3.4: it runs as
`bm2_etl` against `MAJADU_ETL_DSN` (`ops/scripts/cutover.sh:340-341,540`), which
does not bypass either, and its fix is the `scoped` facade in §3.4.

The risk is the same in all three groups: the "run it as the owner" rule is
tribal knowledge. Step 2 adds one line to each tool's usage text naming the role,
and the parity probe (§6.3) is what proves the rule held.

---

## 4. Rollback: what `:prev` means once policies are on

This is the part that decides the shape of the whole plan.

### 4.1 The failure it names

Policies live in the database. An image does not. The moment
`enable row level security` is recorded, every `bm2_app` statement that runs
without a GUC returns **zero rows**. An image that does not set the GUC — that is,
any image older than step 1 — therefore starts answering empty pages while
`/readyz` stays 200, `/version` stays correct and `smoke.sh` stays green (§6.2).

`ops/scripts/deploy-vps.sh` turns that into a live outage, not a failed deploy:
`wait_ready` (`ops/scripts/deploy-common.sh:52-61`) only polls `/readyz`, and the
readiness rollback at `deploy-vps.sh:727-747` then re-tags `:prev` and restarts
it. If `:prev` cannot set the GUC, the rollback completes into a process that
serves an empty product, and the deploy records success.

### 4.2 So: two steps, and the rule that keeps `:prev` alive

The migration **cannot ship in the release that introduces the GUC.** That is
the answer, plainly: it needs a two-step deploy.

**Step 1 — release N, plumbing only, no schema change.**

- `Db.scoped(communityId)`, the GUC write in `withConn`, the `threadvar`
  install in `scoped()` and its reset in `route()` (§2).
- Both the scoped-facade paths and the pre-context doors from §1.3
  (`session.links` resolve, `community.invite` lookup, `inCommunitySlug`,
  `requestJoin`'s settings read) are restructured to set the GUC or to read the
  root table first. All of it is invisible while no policy exists — which is
  exactly what makes it safe to deploy: if anything is wrong, the failure is a
  normal 500 on one route, not a silent empty product.
- The three scheduled jobs of §3.6 (`janitorcli`, `ranksnapshot`,
  `ratingingest`) get their per-community loop here, for the same reason: they
  must already set the GUC before any release rolls back to them.
- Ships with `./task check` and the isolation matrix green.
- `:prev` after this deploy is release N-1, which does not set the GUC and does
  not need to, because no policy exists yet. Rollback is the normal one and works.

**Step 2 — release N+1, one deploy later, schema.**

- One migration: `session.tenant_id()`, `alter view session.game_results set
  (security_invoker = true)`, then `enable row level security` plus `create
  policy` on the 30 tables from §1.2, then the two definer resolvers.
- The three `bm2_app` jobs from §3.6 ship their per-community loop in step 1
  too, not here. A job that only learns to set the GUC in the same release as
  the policies is the same mistake as an image that does: it works, until the
  release is rolled back to a `:prev` that does not.
- `:prev` at this point is release N, which sets the GUC. It serves the policy
  schema correctly: same facade, same settings, empty tables it never reads are
  irrelevant.
- `:prev` must therefore be verified to be at least N before the tag is taken.
  The mechanical check is the deploy log's own record:
  `deploy/last-release.json.prev` must name a version that contains the
  `Db.scoped` code. If it does not — a hotfix deployed in between, an image
  pulled from elsewhere — the step-2 migration is refused and the release is
  re-cut. This belongs in `docs/ops/release.md` §4 next to the existing
  single-community criterion.

**Never** ship the GUC and the policies in the same release. It looks like one
release and it costs one deploy; it also deletes the only rollback target that
works.

### 4.3 The three rollback paths, in the order to use them

1. **Emergency brake, no deploy: turn row security off.**
   ```sql
   alter table <schema>.<table> disable row level security;
   ```
   as `bm2_owner`. Instant, no lock beyond the table's `ACCESS EXCLUSIVE` for
   milliseconds (this database is 13-15 MB, `docs/db/rls-tenancy-options.md`
   §2a), no data touched, policies stay defined and are simply ignored (§5.9 of
   the manual). The database returns to exactly release N's behaviour — the
   app-level guard — and the code that sets the GUC keeps setting it harmlessly.
   This is the right first move for both failure directions: too narrow (empty
   pages) and too wide (leaked rows).
2. **Deploy rollback to `:prev`.** Valid only under the rule in §4.2: `:prev`
   is release N or later. `ops/scripts/release-rollback.sh` does it and then
   requires `/readyz` and `/version` to name the previous release; that check
   proves the process started, **not** that it reads rows, so the parity probe
   from §6.3 runs after it.
3. **Forward fix.** A new release with `drop policy` / corrected predicates.
   Policies are additive and dropping one is not a data change, so this is
   always available and never needs a data migration. Migrations are
   forward-only in this repository (`tools/dbtools/main.nim` has no down path),
   so path 3 is the only one that changes the schema again.

Retention still holds `:local` and `:prev` only, so path 2 always has a target;
there is no third tag to fall back to, which is another reason §4.2's rule is a
release rule and not advice.

---

## 5. The gate: what must be green before the migration lands

`apps/api/tests/integration/community_isolation_matrix_test.nim` (572 lines) is
**the app-level half, and only the app-level half**. It walks every contract
route whose path carries `{slug}` out of the generated table and calls each one
from a B session against a row of A; it asserts 58 operations across 39 paths
(the contract has 76 operations over 55 paths), and its `knownRed` list is
empty.

Two measured reasons it cannot be the RLS gate:

- **It runs as the owner.** It boots the app with `newApp(db, ...)`
  (`apps/api/tests/http_support.nim:142`) on `MAJADU_PG_DSN`, and in CI that DSN
  is `postgresql://postgres:postgres@...` (`.github/workflows/ci.yml:209`), a
  superuser; locally it is the developer's own role. A superuser bypasses row
  security, so with policies on and the GUC missing the matrix would still pass.
- **It tests refusal, not invisibility.** Its contract is "a foreign id is
  refused with 400/403/404/409/412". The failure mode RLS introduces is "a read
  returns zero rows and a write silently matches nothing", which the matrix
  cannot distinguish from a correct refusal.

So the matrix stays as the guard on the routes, and the migration lands with
four new tests:

1. **`policy_coverage_test` — the static half, the archcheck equivalent in SQL.**
   As the owner, read `pg_class`/`pg_policy` and assert, from the catalogue
   rather than a hand-kept list:
   - for every base table with a `community_id` column except
     `community.membership`: `relrowsecurity = true` and at least one policy;
   - `session.game_results` has `security_invoker=true` in `reloptions`;
   - `relforcerowsecurity = false` on every table (the owner bypass is wanted);
   - `account.audit` has exactly one policy for `bm2_app` whose qual admits
     `community_id is null`, and one for `bm2_audit_prune`;
   - zero tables outside the tenant set have row security on.

   This is the test that fails when a new tenant table ships without a policy,
   which is the actual regression risk after the release: the catalogue check
   needs no fixture and no second community.
2. **`rls_isolation_test` — the dynamic half, as the application role.**
   Two communities, then `set role bm2_app` (both the CI superuser and the local
   dev role may assume it; `bm2_app` is `nologin`, which does not block `SET
   ROLE`). With the GUC set to A, every tenant table returns only A's rows and a
   write naming a B row is refused (`with check` violation or zero rows); with
   the GUC unset, the same reads return **zero rows, never B's**, and a write is
   refused. The unset case is the one that would have caught the `:prev`
   problem in §4.1 before the deploy did.
3. **The pool leak test, on a pool of size 1.** One scoped read (community A),
   then one unscoped read on the same pool: the second must return zero rows, not
   A's. This is the test for the `threadvar` install/clear in §2.3 and for the
   unconditional `set_config`; it is three statements and it is the only thing
   that proves the mechanism, as opposed to the predicates.
4. **The job-wrote-something test, for each of the three units in §3.6.** A
   scheduled job that exits 0 after doing nothing is the obstacle this plan rates
   worst, and no existing check catches it. One case per tool, on a database with
   policies on and a fixture older than the retention window:
   - `janitorcli` prints `deleted > 0` and the expired `session.links` row is
     gone — the existing `janitor_test.nim` already pins the clock and counts
     rows, so this is one more case;
   - `ranksnapshot` writes one `rating.snapshots` row per player on the board, so
     `rows > 0` and the count matches `board(...)`;
   - `ratingingest tick` writes `events > 0` for a session that has none yet.

   All three can assert on the tool's own JSON output, which is the artefact a
   person would otherwise read as success.

`tools/dbtools/tests/integration/migrations_test.nim` stays green unchanged: it
applies every shipped migration from an empty database, which is what proves the
new file runs in order and that `verify` is clean afterwards.

None of the four exists yet. Nothing in this document may land before (1) and
(2) are green against a database, (3) is green against a pool of one, and (4) is
green for all three units.

---

## 6. Sequencing against production

### 6.1 The second environment is gone

The options paper assumes "RC first, production second". The RC instance and
`bm2_rc` were purged on 2026-11-21 by the owner's order
(`ops/scripts/deploy-dispatch.sh:16-19`, `docs/ops/operations.md:56-57`), and
`deploy-dispatch.sh` now routes `refs/heads/main` only. There is no RC to run
first.

What replaces it, in order of cost:

1. **A throwaway database restored from the last nightly dump.**
   `ops/scripts/restore.sh --file <dump> --target bm2_rls_test --recreate`
   (`backup.sh` takes the daily `bm2` dump as `bm2_owner`,
   `ops/env/prod-tools.env.example:26-30`). This is the only rehearsal that runs
   against real production shapes and real row counts. It is also the restore
   drill this migration should be recorded alongside.
2. **`tools/rehearsal`** for the deploy path (it runs the real
   `cutover.sh`/`rollback.sh` against `bm_staging`), but it does not exercise the
   API against the policy schema and needs Podman, a systemd user session and
   two databases on the VPS. Useful, not sufficient.
3. **CI + `bm2_dev`** for the mechanical half only: policies apply from empty,
   the three tests are green.

Nothing in step 2 of the deploy goes near production on the strength of CI
alone. The order is: throwaway restore → step 1 → step 2, and step 1 is at least
one full deploy ahead of step 2 by rule (§4.2).

### 6.2 What the deploy window can and cannot see

Measured, because this is where the plan is weakest:

- `ops/scripts/smoke.sh` checks six things: `/version` names the released
  version, `/healthz` is ok, `/readyz` is 200, `/metrics` is 404, an unknown
  share code is 404, `/auth/me` is 401. **Not one of them reads tenant rows.**
- `/readyz` (`apps/api/src/app.nim:2150-2205`) reads `pg_class` for 13 required
  relations and `platform.cutover_state`. It proves the schema is migrated; it
  cannot see a policy.
- The readiness rollback (`deploy-vps.sh:727-747`) trusts `/readyz`, so it would
  roll a broken-policy release forward as a success, or roll back to an image
  that returns empty pages and record that as recovered. Step 2 wants one extra
  line after `STEP="smoke"` (`:748-756`): after `smoke.sh` passes, run the parity
  probe against the same database and `fail` on a mismatch, so a policy mistake
  stops the deploy before `last-release.json` is rewritten at `:771-774`.

So the deploy window has **no built-in signal** for this change. The signal has
to be added by hand, and it is one procedure:

### 6.3 The parity probe (the thing to build with step 1, not after step 2)

A read-only script, `ops/scripts/rls-check.sh`, run by the operator as
`bm2_owner` against the target database. For each community in
`platform.community`, and for each of the 30 policy tables:

```
owner count:   select count(*) from <t> where community_id = <id>      -- bypasses RLS
scoped count:  begin; select set_config('majadu.community_id', <id>, true);
               set local role bm2_app;
               select count(*) from <t>;   -- policy applies
               rollback;
```

Three assertions, printed per table, exit non-zero on any:

- `scoped == owner` for every table and community (catches too narrow and a
  missing GUC);
- with the GUC unset, `scoped == 0` (catches a fail-open predicate and a `using
  (true)` written by mistake);
- with community A's GUC, no row of B is visible (`scoped(A) + scoped(B) ==
  owner(all)` for the two communities that exist).

Run it at three points: before step 1 (baseline, must already show
`scoped == owner` because no policy exists), after step 1 (must be identical —
this proves the plumbing did not narrow anything), and immediately after step 2
and after any rollback. It takes seconds on 13-15 MB.

### 6.4 What a wrong policy looks like from outside

| Direction | What a person sees | What the logs say | What notices it |
|---|---|---|---|
| Too narrow, or the GUC is missing | HTTP 200 with empty lists and empty pages; a PATCH or DELETE of a row that exists answers 404 "not found"; `/readyz` 200, `/version` correct, `/healthz` ok | nothing; maybe a `DbError` 42501 or "new row violates row-level security policy" on the arbiter statements of §3.1 | the parity probe, or a person reporting an empty page. **Not** smoke, not `/readyz`, not the isolation matrix |
| Too wide (`using (true)` or a reversed comparison) | every list, including another community's rows; no error anywhere | nothing | the parity probe (unset-GUC case and the A+B sum), or the matrix if it is re-run against the policy schema |
| Policies on a table with no policy written (default deny) | that feature only: 200 with empty rows | nothing | `policy_coverage_test` in CI, before the deploy |
| A scheduled job with no GUC (§3.6) | nothing today; instead ratings stop moving, daily snapshots gap, and expired share links and invites pile up | `{"deleted":0}` / `{"communities":N,"rows":0}` and exit 0 — the unit is green | the job test from §5 item 4, or a user noticing a frozen board days later. **Not** the alert unit |

The blast radius is the whole database, not one community: policies live per
database and this deployment is the only one.

### 6.5 The window itself

- Step 1 deploy is a normal deploy: no migration, so `dbtools verify` passes,
  `:prev` rotates as usual, the parity probe is identical before and after.
  Nothing to watch beyond the usual smoke.
- Step 2 deploy runs `dbtools migrate` (one transaction and one advisory lock,
  `set local lock_timeout = '5s'`, `set local statement_timeout = '60s'`,
  `tools/dbtools/main.nim:140-147`; invoked at `ops/scripts/deploy-vps.sh:580-585`)
  on a 13-15 MB database: milliseconds of `ACCESS EXCLUSIVE` per table, all inside
  one transaction, well under the 900 s tool timeout (`deploy-vps.sh:184`). If
  `migrate` fails, `fail` exits at `:584` before `:local` moves at `:624` and the
  running release is untouched.
- After `migrate` succeeds there is one unavoidable gap: the database has the
  policies and the old container is still serving until `:local` rotates and the
  unit restarts (`:624-726`). The running container is release N (it sets the
  GUC), so it serves correctly in that gap; that is the other reason step 1 must
  be its own release. A step-2 deploy from an N-1 container would serve empty
  pages for the length of the rotate-and-restart.
- Detection inside the window: `wait_ready` (60 s) plus the probe, and one
  authenticated read of a list endpoint by the operator before `:prev` is
  released as the rollback target. If the probe fails, path 1 in §4.3
  (`disable row level security`) ends the incident in one statement, and the
  forward fix is a new release.

---

## 7. What this document did not verify

- **No database was read.** Every count comes from the migration files and the
  Nim source in this checkout. The options paper's catalogue numbers (43 tables,
  59 foreign keys, 67 constraints, head 0054) were measured on a live database at
  an older head; mine are source-level counts at head 0060, so a difference
  between the two is expected where migrations changed since, and none of mine
  proves the live catalogue agrees.
- **The production row counts are unknown.** The size of the migration is
  argued from the 13-15 MB database the options paper measured, not from
  production. A production database that is much larger only lengthens an
  `ACCESS EXCLUSIVE` per table that is already milliseconds.
- **The pool numbers are code-derived, not observed.** 8 workers and 10
  connections follow from `countProcessors() = 2` on the host the capacity
  statement names; the container's own CPU view was not read.
- **`set role bm2_app` as a test mechanism was not executed.** Both the CI
  superuser and the local dev role should be able to assume it; that is a
  reading of `ops/dev/pg-up.sh:39-47` and `ops/db/roles.sql:17-31`, not a run.
- **The silent-failure behaviour of the three jobs in §3.6 is argued from the
  code, not observed.** `purgeBatch` returning 0 and `writeSnapshot` inserting 0
  rows both follow from an empty subquery, and neither was run against a
  policy-enabled database. That is precisely why §5 item 4 exists: it is the
  experiment that turns this paragraph into a fact.
- **No statement is proven free of a runtime-assembled query.** The archcheck
  scan reads Nim source; a statement built from a variable still passes it. That
  was true before this plan and is unchanged by it, and it is the one gap a
  policy set closes.
- **`countProcessors()` on the production host was not read**, and the "2 vCPU"
  figure is quoted from `docs/ops/operations.md:245` rather than measured here.
