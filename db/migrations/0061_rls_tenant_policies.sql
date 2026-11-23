-- 0061: row level security, the database-side tenancy guard.
--
-- Step 2 of the two-step RLS release. Step 1 (a release earlier) carries the
-- connection plumbing: `Db.scoped(communityId)`, the `set_config` in
-- `withConn`, and every caller that resolves a community first. None of that is
-- in this file. This file only turns the guard on, so an image that cannot set
-- the GUC is never the image running when the policies appear.
--
-- Why: one production database now holds many communities (ADR-018 revised
-- 2026-11-23). The app-level guard is gone, so tenancy rests on slug dispatch
-- and a static statement scan. A statement that never passes through the scoped
-- facade has no tenant guard at all. RLS is the guard that does not depend on a
-- call site remembering.
--
-- Shape, and the reasons, are in docs/db/rls-migration-plan.md:
--   * 30 of the 31 tables carrying `community_id` get a policy.
--     `community.membership` does not: the query that builds a request's
--     community context joins it to `platform.community` by slug, before any
--     community id exists. A policy keyed on the id would make every login and
--     every `/c/{slug}` request return zero rows, and it cannot work even in
--     principle, because the row that names the community is the row the GUC
--     would have to be read from.
--   * `enable`, never `force`: `bm2_owner` keeps bypassing, which is what
--     migrations, `dbtools seed`, `ownerseed`, backup and the operator tools
--     rely on. Forcing it would need a second bypass mechanism instead.
--   * `bm2_app` and `bm2_etl` are governed; neither bypasses. `bm2_etl` is in
--     the policy on purpose: with RLS enabled and no policy for it, the cutover
--     loader would read and write zero rows and report success. It sets the
--     same GUC through the scoped facade (`docs/db/rls-migration-plan.md` §3.4).
--   * `bm2_audit_prune` gets one policy, on `account.audit` only, because the
--     retention timer deletes by age across every community.
--
-- A missing GUC fails closed. `current_setting(..., true)` returns NULL when
-- unset, `nullif` turns the empty string into NULL, and `community_id = NULL`
-- is NULL, which `using`/`with check` treat as false. So a statement without a
-- tenant sees zero rows and its write is refused. That is the property that
-- makes a forgotten call site a visible bug instead of a silent leak.
--
-- Locking: `enable row level security` and `create policy` take an
-- ACCESS EXCLUSIVE lock on each table for the duration of the statement, which
-- on this database is milliseconds. dbtools applies this whole file in one
-- transaction with `lock_timeout = '5s'`, so a queue behind it turns into a
-- failed deploy rather than a hung service.
--
-- Down path: `alter table <t> disable row level security` for the 30 tables, as
-- the owner. Instant, no data touched, policies stay defined and are ignored.
-- That is rollback path 1 of the plan and it needs no deploy. Dropping the
-- policies and the three functions, then the view reloption, is the complete
-- revert. Nothing in this file changes a row.

-- ---------------------------------------------------------------------------
-- 0. The prune role.
-- ---------------------------------------------------------------------------
--
-- `bm2_audit_prune` is created by `ops/db/roles.sql`, which the deploy and the
-- cutover run before any migration. CI and `ops/dev/pg-up.sh` do not run that
-- file: they create `bm2_owner`, `bm2_app` and `bm2_etl` only. A `create policy
-- ... to bm2_audit_prune` would therefore fail on every fresh test database
-- with "role does not exist", and the whole batch is one transaction, so 0061
-- could not be applied in CI at all.
--
-- The role is created here in the same shape `ops/db/roles.sql` uses: NOLOGIN
-- and no password, so nothing secret is stored and nothing can connect with it.
-- `if not exists` makes this a no-op in production, where `roles.sql` already
-- created it before the migration ran. No CREATEROLE privilege is needed on the
-- path that matters, because the branch is not reached there.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'bm2_audit_prune') then
    begin
      create role bm2_audit_prune nologin;
    exception when insufficient_privilege then
      raise exception
        'bm2_audit_prune does not exist and this role cannot create it; run ops/db/roles.sql first'
        using hint = 'ops/db/roles.sql creates every bm2 role without a password';
    end;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. The tenant predicate.
-- ---------------------------------------------------------------------------

create function session.tenant_id() returns uuid
language sql
stable
set search_path = pg_catalog, pg_temp
as $$
  select nullif(current_setting('majadu.community_id', true), '')::uuid
$$;

comment on function session.tenant_id() is
  'The community the current statement is scoped to, or NULL when none is set. NULL fails closed: every policy comparison against it is false.';

-- ---------------------------------------------------------------------------
-- 2. The view that carries a tenant column must run with the invoker's rights.
-- ---------------------------------------------------------------------------

-- `session.game_results` has no `security_invoker` option, so a query through it
-- runs as the view owner and would keep serving every community's rows beside a
-- complete policy set. `alter view ... set (...)` sets the reloption without
-- restating the query, so the body cannot drift from 0029 while it is hardened.
alter view session.game_results set (security_invoker = true);

-- ---------------------------------------------------------------------------
-- 3. The 30 policies.
-- ---------------------------------------------------------------------------

-- session: 7
alter table session.sessions      enable row level security;
alter table session.courts        enable row level security;
alter table session.games         enable row level security;
alter table session.game_sets     enable row level security;
alter table session.game_skips    enable row level security;
alter table session.participants  enable row level security;
alter table session.links         enable row level security;

-- tournament: 8
alter table tournament.tournaments   enable row level security;
alter table tournament.pairs         enable row level security;
alter table tournament.groups        enable row level security;
alter table tournament.matches       enable row level security;
alter table tournament.teams         enable row level security;
alter table tournament.team_players  enable row level security;
alter table tournament.team_matches  enable row level security;
alter table tournament.team_partai   enable row level security;

-- rating: 5
alter table rating.events        enable row level security;
alter table rating.player_state  enable row level security;
alter table rating.snapshots     enable row level security;
alter table rating.sources       enable row level security;
alter table rating.levels        enable row level security;

-- player: 4
alter table player.players     enable row level security;
alter table player.aliases     enable row level security;
alter table player.claims      enable row level security;
alter table player.merge_log   enable row level security;

-- community: 3 (membership stays without a policy, see the header)
alter table community.invite        enable row level security;
alter table community.join_request  enable row level security;
alter table community.settings      enable row level security;

-- achievement, import, account: 1 each
alter table achievement.earned  enable row level security;
alter table import.row_map      enable row level security;
alter table account.audit       enable row level security;

-- The uniform policy, identical on 28 tables. `session.links` and
-- `community.invite` also get it: only the lookups that start from a secret go
-- around it, through the definer functions in section 5. Every statement a
-- signed-in reader makes against them is still tenant-filtered.
create policy tenant_isolation on session.sessions
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on session.courts
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on session.games
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on session.game_sets
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on session.game_skips
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on session.participants
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on session.links
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on tournament.tournaments
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on tournament.pairs
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on tournament.groups
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on tournament.matches
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on tournament.teams
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on tournament.team_players
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on tournament.team_matches
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on tournament.team_partai
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on rating.events
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on rating.player_state
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on rating.snapshots
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on rating.sources
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on rating.levels
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on player.players
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on player.aliases
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on player.claims
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on player.merge_log
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on community.invite
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on community.join_request
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

-- `community.settings` is tenant-filtered like the rest. The one read that
-- genuinely spans communities, the public `/directory` listing, goes through
-- `community.directory_entries()` in section 5 instead of being exempted here.
create policy tenant_isolation on community.settings
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on achievement.earned
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

create policy tenant_isolation on import.row_map
  for all to bm2_app, bm2_etl
  using (community_id = session.tenant_id())
  with check (community_id = session.tenant_id());

-- `account.audit` is the one table whose policy differs: `community_id` is
-- nullable by design (0004_platform.sql), because a platform-level action has no
-- community to name. Three write paths leave it NULL: the login refusals
-- (`app.nim:176`, `:185`), `denyAudit` for a slug that resolved to nothing
-- (`app.nim:619`), and `account.anonymize`
-- (`modules/account/infrastructure/lifecycle_store.nim:87`). A strict equality
-- would make the refusal handler raise and leave the refusal unaudited.
create policy tenant_isolation on account.audit
  for all to bm2_app, bm2_etl
  using (community_id is null or community_id = session.tenant_id())
  with check (community_id is null or community_id = session.tenant_id());

-- The retention timer connects as `bm2_audit_prune` and deletes by
-- `occurred_at` across every community, so it needs to see all of them. Scoped
-- to that role, which holds `select, delete` on this table and nothing else
-- (`ops/db/roles.sql`). The append-only trigger from 0049 still applies: the
-- timer sets `majadu.audit_maintenance` for its transaction.
create policy audit_prune_all on account.audit
  for all to bm2_audit_prune
  using (true)
  with check (true);

-- ---------------------------------------------------------------------------
-- 4. The view, once its policies are in place.
-- ---------------------------------------------------------------------------

-- Nothing else to do: the reloption is set in section 2, before any policy
-- exists, so no window has the view reading as the owner while the base tables
-- are already guarded.

-- ---------------------------------------------------------------------------
-- 5. The cross-tenant reads.
-- ---------------------------------------------------------------------------
--
-- Three statements read a tenant table before a community id is known, so no
-- scoped facade can serve them. Each becomes one SECURITY DEFINER function
-- owned by `bm2_owner`, with a pinned `search_path` and EXECUTE granted to
-- `bm2_app` only. The rule that makes this safe: the function body is one fixed
-- indexed lookup, the caller cannot influence which columns come back, and
-- everything the caller does *after* it runs on a facade scoped to the returned
-- community id.

-- 5a. A public share link, resolved by its secret before any tenant exists.
-- Mirrors `modules/share/store.nim` `resolve`: the code-hash path first, then
-- the pre-code `/s/{sessionId}` path for links already in a group chat. The
-- caller still decrypts `code_enc` and verifies the AAD, so a wrong row cannot
-- be served even if a hash collided.
create function session.share_link_resolve(
  p_code_hash bytea,
  p_legacy_session_id uuid default null
) returns table (
  link_id       uuid,
  community_id  uuid,
  session_id    uuid,
  key_id        text,
  code_enc      text,
  title         text,
  session_date  text,
  status        text,
  slug          text,
  name          text,
  timezone      text,
  start_time    text,
  slot_minutes  int
)
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
as $$
  select l.id,
         l.community_id,
         l.session_id,
         l.key_id,
         encode(l.code_enc, 'hex'),
         s.title,
         s.session_date::text,
         s.status,
         c.slug,
         c.name,
         c.timezone,
         to_char(s.start_time, 'HH24:MI'),
         s.slot_minutes
    from session.links l
    join session.sessions s
      on s.community_id = l.community_id and s.id = l.session_id
     and s.status in ('draft', 'locked', 'published', 'completed')
    join platform.community c on c.id = l.community_id
   where l.code_hash = p_code_hash
     and l.revoked_at is null
     and (l.expires_at is null or l.expires_at > now())
     and p_code_hash is not null
   union all
  select l.id,
         l.community_id,
         l.session_id,
         l.key_id,
         encode(l.code_enc, 'hex'),
         s.title,
         s.session_date::text,
         s.status,
         c.slug,
         c.name,
         c.timezone,
         to_char(s.start_time, 'HH24:MI'),
         s.slot_minutes
    from session.links l
    join session.sessions s
      on s.community_id = l.community_id and s.id = l.session_id
     and s.status in ('draft', 'locked', 'published', 'completed')
    join platform.community c on c.id = l.community_id
   where p_legacy_session_id is not null
     and l.session_id = p_legacy_session_id
     and l.legacy_id_ok
     and l.revoked_at is null
     and (l.expires_at is null or l.expires_at > now())
     -- Not reached when the code path already answered: `resolve` only tries
     -- the legacy shape after the code lookup returned nothing, and this keeps
     -- the same precedence inside one round trip.
     and not exists (
       select 1
         from session.links l2
        where l2.code_hash = p_code_hash
          and l2.revoked_at is null
          and (l2.expires_at is null or l2.expires_at > now()))
   limit 1
$$;

-- 5b. An invitation, resolved by its token before a community is chosen. This
-- is the read half of `modules/community/infrastructure/invite.nim` `lookup`;
-- the claiming UPDATE still needs a scoped facade or its own function and is
-- called out in the PR body rather than widened here.
create function community.invite_by_token(p_token_hash bytea)
returns table (
  community_id  uuid,
  role          text,
  email_hash    text,
  accepted_at   timestamptz,
  expires_at    timestamptz
)
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
as $$
  select i.community_id,
         i.role,
         i.email_hash,
         i.accepted_at,
         i.expires_at
    from community.invite i
   where i.token_hash = p_token_hash
$$;

-- 5c. The public directory. This one is not a door: no community is being
-- resolved, and the read is *asked* to span every community, so scoping cannot
-- fix it. Without this function the left join to `community.settings` returns
-- no row for any community, `coalesce` falls to the platform default (`false`
-- in `db/seeds/platform_config.sql`), and `GET /directory` answers
-- `{"items":[]}` with 200 while members still see their own community through
-- `community.membership`, which has no policy. That reads as "nobody opted in",
-- not as a bug.
--
-- The filter is the same rule as `directoryVisible` in
-- `modules/community/domain/community.nim`: opted-in, or the caller is already
-- a member. `platform_default` stays a parameter so the L1 registry value keeps
-- coming from the snapshot instead of being frozen into a migration.
create function community.directory_entries(
  p_user_id uuid,
  p_platform_default boolean
) returns table (
  slug    text,
  name    text,
  enabled boolean,
  member  boolean
)
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
as $$
  select c.slug,
         c.name,
         coalesce((s.values ->> 'community.directory_enabled')::boolean,
                  p_platform_default) as enabled,
         (m.user_id is not null) as member
    from platform.community c
    left join community.settings s on s.community_id = c.id
    left join community.membership m
      on m.community_id = c.id and m.user_id = p_user_id
   where coalesce((s.values ->> 'community.directory_enabled')::boolean,
                  p_platform_default)
      or m.user_id is not null
   order by c.slug
$$;

-- A SECURITY DEFINER function is executable by PUBLIC unless it is revoked, and
-- these three read across tenants on purpose. Only the application role calls
-- them; the owner does not need them and no other role may use them.
revoke all on function session.share_link_resolve(bytea, uuid) from public;
revoke all on function community.invite_by_token(bytea) from public;
revoke all on function community.directory_entries(uuid, boolean) from public;

grant execute on function session.share_link_resolve(bytea, uuid) to bm2_app;
grant execute on function community.invite_by_token(bytea) to bm2_app;
grant execute on function community.directory_entries(uuid, boolean) to bm2_app;
