-- 0016: what the cutover must leave behind for the external probe.
--
-- `snapshot_sha256` already lets `/readyz` refuse a database that is not the
-- dump the operator meant to serve. These two columns let a one-minute cron on
-- the VPS compare the release that is running with the release that was
-- imported, and the row counts with the staging database, without a dashboard.

alter table platform.cutover_state
  add column if not exists app_version text,
  add column if not exists rows_imported jsonb not null default '{}'::jsonb;
