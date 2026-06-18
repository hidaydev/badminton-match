-- Expected execution order:
-- 1. supabase/seeds/20260617_legacy_snapshot_backfill.sql
-- 2. supabase/seeds/20260617_bm_identity_seed.sql
-- 3. this file

select * from bm.report_legacy_unresolved_names();
select * from bm.backfill_legacy_sessions();
