drop function if exists bm.report_legacy_unresolved_names();
drop function if exists bm.backfill_legacy_sessions();
drop function if exists bm.backfill_legacy_session(text);

drop schema if exists badminton_match cascade;
