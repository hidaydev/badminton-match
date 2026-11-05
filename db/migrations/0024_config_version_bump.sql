-- 0024: every change to the registry bumps the version the cache watches.
--
-- `ConfigCache` reloads when `platform.config_version.version` changes, and the
-- code comment has always claimed the write bumps it in the same transaction.
-- Nothing did: a value changed by an operator with psql, or by a migration that
-- writes `platform.config` (0021 does), was invisible to a running process until
-- the next restart. The trigger makes the claim true for every writer, so no
-- call site has to remember.

create or replace function platform.bump_config_version() returns trigger
language plpgsql as $$
begin
  update platform.config_version set version = version + 1;
  return null;
end;
$$;

create trigger config_bump_version
  after insert or update or delete on platform.config
  for each statement execute function platform.bump_config_version();