-- =============================================================================
-- 000018 — Ranking poin (papan publik ala BWF)
--   Papan publik memakai POIN (window bergulir 12 minggu, 10 entri terbaik),
--   bukan Glicko. Glicko tetap mesin internal: generator/pairing + detail
--   pemain. Lihat RANKING_POIN_BWF_RANCANGAN.md.
--
--   rank_point_levels: SEMUA nilai poin di satu tabel, bukan if-else di kode,
--   supaya format turnamen baru cukup menambah baris.
--
--     kind            'session' | 'tournament_classic' | 'tournament_team' | ...
--     champion_points poin juara (turnamen) / poin dasar (sesi)
--     round_ratios    {final:1.0, sf:0.7, ...} — pengali per fase
--     enabled         matikan jenis tanpa menghapus riwayat nilainya
--
--   Konfigurasi poin disimpan di rating_config (tabel yang sudah ada) supaya
--   bisa diubah tanpa deploy: rank_window_weeks, rank_best_n,
--   rank_opponent_weight, rank_opponent_clamp, rank_session_base,
--   rank_thin_evidence_n.
--
--   Additive + idempotent (IF NOT EXISTS / ON CONFLICT DO NOTHING).
--   Poin dihitung SAAT BACA (tidak ada tabel materialized) — dengan ~2.5k
--   event, agregasi on-read remeh; lihat §4.6 rancangan.
-- =============================================================================
BEGIN;

CREATE TABLE IF NOT EXISTS bm.rank_point_levels (
  kind            text PRIMARY KEY,
  champion_points numeric NOT NULL DEFAULT 0,
  round_ratios    jsonb   NOT NULL DEFAULT '{}'::jsonb,
  enabled         boolean NOT NULL DEFAULT true,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rank_point_levels_champion_ck CHECK (champion_points >= 0)
);

-- Nilai awal. Angka turnamen adalah usulan yang WAJIB diverifikasi ulang
-- setelah turnamen 23 Mei ter-ingest (§4.4 rancangan) — bukan angka final.
INSERT INTO bm.rank_point_levels (kind, champion_points, round_ratios) VALUES
  ('session',            0,     '{}'::jsonb),
  ('tournament_classic', 15000, '{"final":1.0,"sf":0.7,"qf":0.55,"group":0.4,"participant":0.2}'::jsonb),
  ('tournament_team',    20000, '{"final":1.0,"sf":0.7,"qf":0.55,"group":0.4,"participant":0.2}'::jsonb)
ON CONFLICT (kind) DO NOTHING;

-- Konfigurasi poin — additive, tidak menimpa nilai yang sudah diset operator.
INSERT INTO bm.rating_config (key, value) VALUES
  ('rank_window_weeks',    '12'::jsonb),
  ('rank_best_n',          '10'::jsonb),
  ('rank_opponent_weight', 'true'::jsonb),
  ('rank_opponent_clamp',  '[0.5, 1.5]'::jsonb),
  ('rank_session_base',    '250'::jsonb),
  ('rank_thin_evidence_n', '3'::jsonb)
ON CONFLICT (key) DO NOTHING;

GRANT SELECT, INSERT, UPDATE, DELETE ON bm.rank_point_levels TO majadu_app;

COMMIT;
