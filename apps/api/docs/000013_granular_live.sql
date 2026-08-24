-- =============================================================================
-- 000013 — Granular live (clean break dari snapshot PUT)
--   Row-level OCC: scheduled_games.version (If-Match per game).
--   Idempotency persistent (menggantikan map in-memory — survive restart).
--   Outbox events (durable SSE replay via GET /sessions/{id}/events).
--
--   Additive + idempotent (IF NOT EXISTS). Backward compat: snapshot PUT
--   tetap jalan (tidak membaca kolom baru). Granular path membaca version.
--
--   Apply dev: remap prefix bm. → bm_dev (sed), dan search_path di arahkan
--   ke schema target per-koneksi (bukan hardcode — pattern 000011).
-- =============================================================================
BEGIN;

-- 1) Per-game version untuk OCC granular (updated_at + trigger sudah ada:
--    bm_scheduled_games_set_updated_at). Backfill = DEFAULT 1.
ALTER TABLE bm.scheduled_games
  ADD COLUMN IF NOT EXISTS version bigint NOT NULL DEFAULT 1;

-- 2) Idempotency keys persistent (PK per session+key, TTL 24h via expires_at)
CREATE TABLE IF NOT EXISTS bm.idempotency_keys (
  session_id uuid NOT NULL REFERENCES bm.sessions(id) ON DELETE CASCADE,
  key text NOT NULL,
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  PRIMARY KEY (session_id, key)
);
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_expires_at
  ON bm.idempotency_keys(expires_at);

-- 3) Outbox events (event sourcing lite untuk SSE delta/replay)
CREATE TABLE IF NOT EXISTS bm.outbox_events (
  id bigserial PRIMARY KEY,
  session_id uuid NOT NULL REFERENCES bm.sessions(id) ON DELETE CASCADE,
  aggregate text NOT NULL,
  aggregate_id text NOT NULL,
  event_type text NOT NULL,
  payload jsonb NOT NULL,
  version bigint NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_outbox_events_session_id_id
  ON bm.outbox_events(session_id, id);

-- 4) Grants — pola sama dengan migration lain (write-path Go langsung ke tabel)
GRANT SELECT, INSERT, UPDATE, DELETE ON bm.idempotency_keys, bm.outbox_events TO majadu_app;
GRANT USAGE, SELECT ON SEQUENCE bm.outbox_events_id_seq TO majadu_app;

COMMIT;
