-- =============================================================================
-- 000022 — Ambang minimum sesi untuk tampil di papan ranking poin
--
--   rank_min_sessions — jumlah entri (sesi) minimum dalam window 12 minggu
--   sebelum seorang pemain boleh tampil di papan publik dan halaman ranking.
--   0 = tanpa ambang. Default 3.
--
--   Additive & idempotent: hanya menambah satu baris config, tidak menimpa
--   nilai yang sudah diset operator. Tidak ada perubahan skema.
--
-- Apply manual via psql ke schema bm (lihat docs/backend/README.md).
-- =============================================================================
BEGIN;

INSERT INTO bm.rating_config (key, value) VALUES
  ('rank_min_sessions', '3'::jsonb)
ON CONFLICT (key) DO NOTHING;

COMMIT;
