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
GRANT USAGE, CREATE ON SCHEMA public TO bm2_app;
GRANT USAGE ON SCHEMA public TO bm2_etl;

-- The v1 archive is never reachable from bm2 roles (O-41). This block runs only
-- when the archive database exists.
SELECT format(
  'REVOKE ALL ON DATABASE bm FROM bm2_app, bm2_etl'
)
WHERE EXISTS (SELECT 1 FROM pg_database WHERE datname = 'bm') \gexec
