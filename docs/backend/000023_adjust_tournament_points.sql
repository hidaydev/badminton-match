-- =============================================================================
-- 000023 — Rasionalisasi bobot poin turnamen vs sesi reguler
--
--   Menyeimbangkan poin turnamen agar tidak mendominasi papan peringkat secara
--   berlebihan terhadap sesi reguler (rata-rata ~700-800 poin per sesi):
--   - tournament_classic: champion 15.000 -> 2.500 (setara ~3-4 sesi reguler)
--   - tournament_team:    champion 20.000 -> 3.000 (setara ~4 sesi reguler)
--
--   Rasio babak (round_ratios):
--     final:       1.0   (Classic 2.500 / Team 3.000)
--     runner_up:   0.85  (Classic 2.125 / Team 2.550)
--     sf:          0.70  (Classic 1.750 / Team 2.100)
--     qf:          0.55  (Classic 1.375 / Team 1.650)
--     group:       0.40  (Classic 1.000 / Team 1.200)
--     participant: 0.20  (Classic 500   / Team 600)
--
--   Setelah migration ini di-apply via psql, tekan tombol "Rebuild All" di UI
--   Admin Ratings (atau POST /ratings/rebuild-all) untuk menghitung ulang papan
--   secara historis.
--
-- Apply manual via psql ke schema bm (lihat docs/backend/README.md).
-- =============================================================================
BEGIN;

UPDATE bm.rank_point_levels
SET champion_points = 2500,
    round_ratios = '{"final":1.0,"runner_up":0.85,"sf":0.7,"qf":0.55,"group":0.4,"participant":0.2}'::jsonb,
    updated_at = now()
WHERE kind = 'tournament_classic';

UPDATE bm.rank_point_levels
SET champion_points = 3000,
    round_ratios = '{"final":1.0,"runner_up":0.85,"sf":0.7,"qf":0.55,"group":0.4,"participant":0.2}'::jsonb,
    updated_at = now()
WHERE kind = 'tournament_team';

COMMIT;
