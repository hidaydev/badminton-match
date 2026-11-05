-- Privileges for one bm2 database. Applied by ops/dev/pg-up.sh with
--   psql -d <db> -v db=<db> -f ops/dev/roles.sql
-- Role creation and passwords stay in pg-up.sh so no secret lands in Git.
--
-- bm2_owner: DDL and migrations
-- bm2_app:   application DML
-- bm2_etl:   reads staging, writes bm2 only during cutover

REVOKE CONNECT ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO bm2_app, bm2_etl;

ALTER SCHEMA public OWNER TO bm2_owner;
-- Same least privilege as production (ops/db/roles.sql): the app gets USAGE,
-- never CREATE. Dev runs as the owner DSN, so nothing here needs DDL rights.
REVOKE CREATE ON SCHEMA public FROM bm2_app;
GRANT USAGE ON SCHEMA public TO bm2_app;
GRANT USAGE ON SCHEMA public TO bm2_etl;

DO $$
BEGIN
  IF has_schema_privilege('bm2_app', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'bm2_app can still create objects in schema public';
  END IF;
END $$;

-- The v1 archive is never reachable from bm2 roles (O-41). This block runs only
-- when the archive database exists.
SELECT format(
  'REVOKE ALL ON DATABASE bm FROM bm2_app, bm2_etl'
)
WHERE EXISTS (SELECT 1 FROM pg_database WHERE datname = 'bm') \gexec
