-- =============================================================================
-- 000014 — Skip per-game (one game only, vs absent whole session)
--   Additive + idempotent (IF NOT EXISTS). Backward compat: old code ignores
--   new column (DEFAULT '{}'), granular skip path reads/writes it.
-- =============================================================================
BEGIN;

ALTER TABLE bm.scheduled_games
  ADD COLUMN IF NOT EXISTS skipped_player_refs TEXT[] NOT NULL DEFAULT '{}';

COMMIT;
