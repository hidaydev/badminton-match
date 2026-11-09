-- 0040: every server-minted id is a UUIDv7.
--
-- The application already mints v7 ids in `shared/platform-lib/uuidv7.nim`.
-- The remaining `gen_random_uuid()` defaults produced v4 values for the rows
-- the application does not id itself (`account.audit`, `rating.events`,
-- `platform.outbox`, invites, flows and tickets), so the hottest write tables
-- landed on random index leaves and `id` had two orderings in one database.
--
-- PostgreSQL 18 ships `uuidv7()`, so no wrapper is needed. The loop keeps the
-- change to the defaults: a column the application always supplies is not
-- affected by its default.
do $$
declare
  target record;
begin
  for target in
    select n.nspname as schema_name, c.relname as table_name,
           a.attname as column_name
      from pg_attrdef d
      join pg_class c on c.oid = d.adrelid
      join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid and a.attnum = d.adnum
     where n.nspname in ('platform', 'session', 'player', 'rating',
                         'tournament', 'achievement', 'community', 'auth',
                         'account')
       and pg_get_expr(d.adbin, d.adrelid) = 'gen_random_uuid()'
  loop
    execute format('alter table %I.%I alter column %I set default uuidv7()',
      target.schema_name, target.table_name, target.column_name);
  end loop;
end $$;
