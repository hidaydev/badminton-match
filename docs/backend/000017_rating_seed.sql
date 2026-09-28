-- =============================================================================
-- 000017 — Benih rating musim (seed) untuk rating_players
--   Masalah: rebuildAll menurunkan ulang seluruh rating dari events. Sebelumnya
--   benih selalu "mid kelas" (players.tier) sehingga rebuild idempotent.
--   Setelah benih pemain lama diubah menjadi "rating terakhir + RD naik",
--   rebuild jadi TIDAK idempotent: benihnya diambil dari rating_players hasil
--   rebuild sebelumnya, sehingga rating naik tiap kali rebuild dijalankan
--   (terukur: 1495 → 1525 → 1554 untuk satu sesi yang sama).
--
--   Solusi: benih disegel ke kolom terpisah, dan HANYA ditulis oleh
--   CloseAndStartSeason (sekali per musim). rebuildAll membaca kolom ini dan
--   mengabaikan rating_players saat ini, sehingga hasilnya selalu sama.
--
--   Semantik:
--     seed_rating NULL & player punya tier  → pemain baru, pakai mid kelas
--     seed_rating NOT NULL                  → pemain lama, pakai rating terakhir
--     seed_rd     NULL                      → pakai initial RD dari config
--     seed_set_at                           → kapan benih disegel (audit)
--
--   Additive + idempotent (IF NOT EXISTS). Backward compat: kolom NULL untuk
--   semua baris lama → perilaku identik dengan "pemain baru" sampai musim
--   berikutnya disegel.
-- =============================================================================
BEGIN;

ALTER TABLE bm.rating_players
  ADD COLUMN IF NOT EXISTS seed_rating double precision NULL,
  ADD COLUMN IF NOT EXISTS seed_rd     double precision NULL,
  ADD COLUMN IF NOT EXISTS seed_set_at timestamptz    NULL;

COMMENT ON COLUMN bm.rating_players.seed_rating IS
  'Rating benih musim berjalan. NULL = pemain baru (pakai mid kelas). Diisi CloseAndStartSeason.';
COMMENT ON COLUMN bm.rating_players.seed_rd IS
  'RD benih musim berjalan (sudah ditumbuhkan sesuai jeda). NULL = pakai initial RD.';
COMMENT ON COLUMN bm.rating_players.seed_set_at IS
  'Kapan benih disegel. NULL = belum pernah disegel (pemain baru / sebelum migrasi ini).';

COMMIT;
