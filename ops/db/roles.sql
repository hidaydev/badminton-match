-- Production privileges for the bm2 database and the v1 archive.
--
--   psql -d bm2 -v db=bm2 -v ON_ERROR_STOP=1 < ops/db/roles.sql
--
-- Roles are created here without a password; cutover.sh sets LOGIN and the
-- password from the environment file, so no secret is stored in the repository.
--
-- O-41: after the cutover the v1 database is a read-only archive. The bm2 roles
-- must not be able to connect to it, and this file asserts that instead of
-- assuming the REVOKE worked.

\set ON_ERROR_STOP on

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'bm2_owner') then
    create role bm2_owner nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'bm2_app') then
    create role bm2_app nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'bm2_etl') then
    create role bm2_etl nologin;
  end if;
  -- Pruning is not the owner's job. This role can see and delete rows in
  -- account.audit and nothing else, so the retention timer runs without a
  -- credential that can also change the schema.
  if not exists (select 1 from pg_roles where rolname = 'bm2_audit_prune') then
    create role bm2_audit_prune nologin;
  end if;
end $$;

-- The table does not exist before 0004_platform.sql, so the grants are
-- generated only when the migration has run.
select 'grant usage on schema account to bm2_audit_prune'
where to_regclass('account.audit') is not null \gexec
select 'grant select, delete on account.audit to bm2_audit_prune'
where to_regclass('account.audit') is not null \gexec
-- The tool reads its window from the registry (audit.retention_days) through the
-- same snapshot every other process loads, so it needs the two registry tables.
-- They are read-only and hold configuration, not secrets: the OIDC client secret
-- and the share-code keyring live in the env file, never in platform.config.
select 'grant usage on schema platform to bm2_audit_prune'
where to_regclass('platform.config') is not null \gexec
select 'grant select on platform.config, platform.config_version to bm2_audit_prune'
where to_regclass('platform.config') is not null \gexec

do $$
begin
  if to_regclass('account.audit') is null then
    return;
  end if;
  if not has_table_privilege('bm2_audit_prune', 'account.audit', 'DELETE') then
    raise exception 'bm2_audit_prune cannot delete from account.audit';
  end if;
  if has_table_privilege('bm2_audit_prune', 'account.audit', 'UPDATE') then
    raise exception 'bm2_audit_prune can update account.audit';
  end if;
  if not has_table_privilege('bm2_audit_prune', 'platform.config', 'SELECT') then
    raise exception 'bm2_audit_prune cannot read platform.config';
  end if;
  if has_table_privilege('bm2_app', 'account.audit', 'DELETE') then
    raise exception 'bm2_app can delete from account.audit';
  end if;
  -- DDL is the owner's job; a prune role that could create objects in public
  -- could also replace the table it is allowed to empty.
  if has_schema_privilege('bm2_audit_prune', 'public', 'CREATE') then
    raise exception 'bm2_audit_prune can create objects in schema public';
  end if;
  if exists (
    select 1
    from pg_auth_members m
    join pg_roles r on r.oid = m.member
    where r.rolname = 'bm2_audit_prune'
  ) then
    raise exception 'bm2_audit_prune is a member of another role';
  end if;
end $$;

revoke connect on database :"db" from public;
grant connect on database :"db" to bm2_app, bm2_etl, bm2_audit_prune;

alter schema public owner to bm2_owner;
-- The application role reads and writes rows, never DDL: 0001_core.sql says
-- "the owner runs migrations; the app never gets DDL". CREATE on `public` would
-- let bm2_app create objects (and therefore bypass the owner's schema grants),
-- so it is revoked explicitly for hosts that ran an older copy of this file.
revoke create on schema public from bm2_app;
grant usage on schema public to bm2_app;
grant usage on schema public to bm2_etl;

do $$
begin
  if has_schema_privilege('bm2_app', 'public', 'CREATE') then
    raise exception 'bm2_app can still create objects in schema public';
  end if;
end $$;

-- `bm` is the frozen v1 archive (O-41): the v2 roles must not reach it, but v1
-- must still reach it after a rollback. Both facts follow from the database ACL.
--
-- `bm` normally carries the default ACL, which grants CONNECT to PUBLIC -- so
-- every role can connect, and revoking "all on database bm from bm2_app, ..."
-- removes nothing because no per-role grant exists. The v2 roles have to be shut
-- out by revoking PUBLIC's CONNECT and granting it back to the one role v1
-- logs in as. Anything else leaves the archive open to every role on the host.
--
-- Only the owner of `bm` (or a superuser) can change this: on qouver1 that is
-- `qouver`, while this file is applied with `bm2_owner`'s DSN. So the statements
-- are emitted only when the caller can actually alter `bm`; otherwise they would
-- warn "no privileges could be revoked" and change nothing. Either way the
-- assertion below reports a hole instead of pretending it was closed.
-- One transaction from here to the assertions: `\gexec` otherwise autocommits
-- each statement, so a failing assert would leave the ACL half-applied.
begin;

-- The revoke is gated on the grantee existing: it closes the archive to every
-- role, and the GRANT below is what lets v1 back in. Without `majadu_app` the
-- revoke would shut v1 out of its own archive, which is the one outcome the
-- comment above forbids. A rebuilt host has the database back but not the role
-- (roles are not in a dump), so this is reachable, not theoretical.
select 'revoke connect on database bm from public'
where exists (
  select 1 from pg_database d
  where d.datname = 'bm' and pg_has_role(current_user, d.datdba, 'USAGE')
)
  and exists (select 1 from pg_roles where rolname = 'majadu_app') \gexec
select 'revoke all on database bm from bm2_app, bm2_etl, bm2_audit_prune'
where exists (
  select 1 from pg_database d
  where d.datname = 'bm' and pg_has_role(current_user, d.datdba, 'USAGE')
) \gexec
select 'grant connect on database bm to majadu_app'
where exists (
  select 1 from pg_database d
  where d.datname = 'bm' and pg_has_role(current_user, d.datdba, 'USAGE')
)
  and exists (select 1 from pg_roles where rolname = 'majadu_app') \gexec

-- The assertions below fail the run only when this session could have closed the
-- hole, which is the same condition the REVOKEs above use. A rehearsal or a
-- cutover runs as bm2_owner, which cannot touch bm's ACL: failing there would
-- abort a run that has nothing to fix, so the hole is reported as a notice and
-- left to the owner of bm (`qouver`).
do $$
declare
  can_fix boolean;
begin
  if not exists (select 1 from pg_database where datname = 'bm') then
    return;
  end if;
  select pg_has_role(current_user, d.datdba, 'USAGE') into can_fix
  from pg_database d
  where d.datname = 'bm';

  -- Revoking PUBLIC's CONNECT without the grant back locks v1 out of its own
  -- archive. The REVOKE above is gated on the same role existing, so this only
  -- reports the reason the archive was left alone instead of failing after it
  -- had already been shut.
  if can_fix and not exists (select 1 from pg_roles where rolname = 'majadu_app') then
    raise exception
      'role majadu_app does not exist: revoking PUBLIC connect on bm would lock v1 out of its own archive. Create the v1 login role first (ops/env/*.v1 names it)';
  end if;

  -- v1 logs in as majadu_app (see ops/env/*.v1); without CONNECT a rollback
  -- restores an image that cannot open its own database.
  if exists (select 1 from pg_roles where rolname = 'majadu_app')
     and not has_database_privilege('majadu_app', 'bm', 'CONNECT') then
    if can_fix then
      raise exception
        'majadu_app cannot connect to bm: v1 would not survive a rollback. Run "grant connect on database bm to majadu_app" as the owner of bm';
    else
      raise notice
        'majadu_app cannot connect to bm; this session is not the owner of bm, so the grant was not attempted';
    end if;
  end if;
  if can_fix and has_database_privilege('bm2_app', 'bm', 'CONNECT') then
    raise exception
      'bm2_app can still connect to bm (O-41). Run "revoke connect on database bm from public" and "grant connect on database bm to majadu_app" as the owner of bm';
  elsif has_database_privilege('bm2_app', 'bm', 'CONNECT') then
    raise notice
      'bm2_app can still connect to bm (O-41); this session is not the owner of bm, so the revoke was not attempted';
  end if;
  if can_fix and has_database_privilege('bm2_etl', 'bm', 'CONNECT') then
    raise exception
      'bm2_etl can still connect to bm (O-41). Run "revoke connect on database bm from public" and "grant connect on database bm to majadu_app" as the owner of bm';
  elsif has_database_privilege('bm2_etl', 'bm', 'CONNECT') then
    raise notice
      'bm2_etl can still connect to bm (O-41); this session is not the owner of bm, so the revoke was not attempted';
  end if;
  if can_fix and has_database_privilege('bm2_audit_prune', 'bm', 'CONNECT') then
    raise exception
      'bm2_audit_prune can still connect to bm (O-41). Run "revoke connect on database bm from public" and "grant connect on database bm to majadu_app" as the owner of bm';
  elsif has_database_privilege('bm2_audit_prune', 'bm', 'CONNECT') then
    raise notice
      'bm2_audit_prune can still connect to bm (O-41); this session is not the owner of bm, so the revoke was not attempted';
  end if;
end $$;

commit;
