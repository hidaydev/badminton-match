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
end $$;

revoke connect on database :"db" from public;
grant connect on database :"db" to bm2_app, bm2_etl;

alter schema public owner to bm2_owner;
grant usage, create on schema public to bm2_app;
grant usage on schema public to bm2_etl;

-- The archive may not exist on a fresh machine, so the revokes are generated
-- only when it does.
select 'revoke all on database bm from bm2_app, bm2_etl'
where exists (select 1 from pg_database where datname = 'bm') \gexec
select 'revoke connect on database bm from public'
where exists (select 1 from pg_database where datname = 'bm') \gexec

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
end $$;
