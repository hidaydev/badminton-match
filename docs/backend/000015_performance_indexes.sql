-- =============================================================================
-- 000015 — PostgreSQL Performance Indexes
--   Additive + idempotent (IF NOT EXISTS). Improves query performance for
--   rating leaderboard 90-day active filter, LATERAL join event deltas lookup,
--   and session player foreign keys.
-- =============================================================================
BEGIN;

-- 1. Partial Index for Active Rating Players Filter (Leaderboard 90 days)
CREATE INDEX IF NOT EXISTS idx_rating_players_active 
  ON bm.rating_players(games_played, last_played_at) 
  WHERE games_played > 0;

-- 2. Composite Index for LATERAL Join lookup in rating_deltas
CREATE INDEX IF NOT EXISTS idx_rating_deltas_player_event 
  ON bm.rating_deltas(player_id, event_id);

-- 3. Composite Sort Index for rating_events
CREATE INDEX IF NOT EXISTS idx_rating_events_sort_lookup 
  ON bm.rating_events(id, date DESC, created_at DESC, source_id DESC, game_order DESC);

-- 4. Foreign Key Lookup Index for session_players & scheduled_games
CREATE INDEX IF NOT EXISTS idx_session_players_session_player 
  ON bm.session_players(session_id, player_id);

CREATE INDEX IF NOT EXISTS idx_scheduled_games_session 
  ON bm.scheduled_games(session_id);

COMMIT;
