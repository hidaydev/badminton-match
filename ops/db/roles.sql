-- Production privileges for the bm2 database and the v1 archive.
--
--   psql -d bm2 -v db=bm2 -v ON_ERROR_STOP=1 -f ops/db/roles.sql
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

-- The archive may not exist on a fresh machine, so the revokes are generated
-- only when it does.
select 'revoke all on database bm from bm2_app, bm2_etl'
where exists (select 1 from pg_database where datname = 'bm') \gexec
-- PUBLIC's CONNECT on bm is deliberately left alone: v1 reaches its own database
-- through it, so revoking it here locks the v1 API out and breaks a rollback
-- after the cutover has run this file. Keeping the v2 roles out is what the
-- revoke above already does.

do $$
begin
  if not exists (select 1 from pg_database where datname = 'bm') then
    return;
  end if;
  if has_database_privilege('bm2_app', 'bm', 'CONNECT') then
    raise exception 'bm2_app can still connect to bm';
  end if;
  if has_database_privilege('bm2_etl', 'bm', 'CONNECT') then
    raise exception 'bm2_etl can still connect to bm';
  end if;
  if has_database_privilege('bm2_audit_prune', 'bm', 'CONNECT') then
    raise exception 'bm2_audit_prune can still connect to bm';
  end if;
end $$;
