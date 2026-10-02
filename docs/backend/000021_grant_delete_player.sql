-- =============================================================================
-- 000021 — Grant EXECUTE delete_player ke role aplikasi
--
--   Tombol "Delete player" di halaman admin selalu gagal (HTTP 500
--   "failed to delete player") untuk SEMUA pemain. Akar masalahnya bukan
--   guard bisnis, melainkan izin: role aplikasi (majadu_app) tidak punya
--   EXECUTE pada fungsi bm.delete_player, sehingga handler menerima
--   "permission denied for function delete_player" dan memetakannya ke 500.
--
--   merge_players sudah punya grant ini; delete_player tidak. Migrasi ini
--   menutup selisihnya. Idempoten: GRANT boleh diulang.
--
--   Catatan: fungsi delete_player sendiri dibuat di 000012 (VPS, tidak ada di
--   repo). Grant di sini menjaga setup ulang dari nol tetap berfungsi.
-- =============================================================================
BEGIN;

GRANT EXECUTE ON FUNCTION bm.delete_player(uuid, boolean) TO majadu_app;

COMMIT;
