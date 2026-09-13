-- =============================================================================
-- 000016 — Player achievements (badge koleksi pemain)
--   Satu baris = satu achievement yang didapat seorang pemain.
--   `achievement_key` = identitas + idempotency (UNIQUE per pemain).
--   `value` hanya dipakai achievement tipe rekor (bisa naik).
--   `earned_at` = tanggal perolehan, tidak berubah walau rekor naik.
--
--   Additive + idempotent (IF NOT EXISTS). Backward compat: tidak menyentuh
--   tabel lain. Apply dev: remap prefix bm. → bm_dev (sed), pola 000015.
-- =============================================================================
BEGIN;

CREATE TABLE IF NOT EXISTS bm.player_achievements (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  player_id       uuid NOT NULL REFERENCES bm.players(id) ON DELETE CASCADE,
  achievement_key text NOT NULL,
  kind            text NOT NULL,
  season_id       uuid NULL REFERENCES bm.rating_seasons(id) ON DELETE SET NULL,
  earned_at       date NOT NULL,
  value           bigint NULL,
  meta            jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT player_achievements_kind_check CHECK (kind IN (
    'attendance', 'volume', 'opponent', 'tournament',
    'tier', 'rating', 'rank', 'social', 'season'
  )),
  UNIQUE (player_id, achievement_key)
);

CREATE INDEX IF NOT EXISTS idx_player_achievements_player
  ON bm.player_achievements(player_id, earned_at DESC);
CREATE INDEX IF NOT EXISTS idx_player_achievements_kind
  ON bm.player_achievements(kind);

-- Pola grants migration lain: write-path Go langsung ke tabel.
GRANT SELECT, INSERT, UPDATE, DELETE ON bm.player_achievements TO majadu_app;

COMMIT;
