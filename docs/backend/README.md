# Backend Migrations (arsip v1)

> **JANGAN DITERAPKAN KE v2.** Folder ini milik backend v1: schema `bm`, nomor
> `000001`–`000023` yang tidak berurutan dengan `db/migrations/` v2. Skema v2 ada
> di [`../../db/migrations`](../../db/migrations) dan deskripsinya di
> [`../handbook/data-model.md`](../handbook/data-model.md).

SQL migrasi untuk schema PostgreSQL `bm`.

| File | Isi |
|---|---|
| `000013_granular_live.sql` | Granular live ops: `scheduled_games` (per-row OCC `version`), `idempotency_keys`, `outbox_events` |
| `000014_skip_per_game.sql` | Skip per-game (`scheduled_games.skipped_player_refs`) |
| `000015_performance_indexes.sql` | 5 composite/partial index performa |
| `000016_player_achievements.sql` | `player_achievements` |
| `000017_rating_seed.sql` | Benih rating musim: `rating_players.seed_rating/seed_rd/seed_set_at` — **dibatalkan `000020`** (ketiga kolom di-drop) |
| `000018_rank_points.sql` | Ranking poin: `rank_point_levels` + 6 config `rank_*` di `rating_config` |
| `000019_rank_snapshots.sql` | `rank_snapshots` — posisi papan per `as_of` untuk panah gerakan |
| `000020_purge_glicko.sql` | Purge peninggalan Glicko & musim: drop kolom rating/seed, tabel `rating_seasons`/`season_player_snapshots`, kolom angka `rating_deltas`, `rating_events.phase_weight`, `player_achievements.season_id`; hapus baris medal `medal:rating`/`season_member:*`; perbarui `merge_players` |
| `000021_grant_delete_player.sql` | `GRANT EXECUTE bm.delete_player` ke `majadu_app` — tanpa ini tombol Delete pemain selalu 500 (permission denied) |
| `000022_rank_min_sessions.sql` | Config `rank_min_sessions` (default 3) — ambang entri minimum agar pemain tampil di papan poin |
| `000023_adjust_tournament_points.sql` | Rasionalisasi poin turnamen: Classic (2.500) & Team (3.000) agar seimbang terhadap sesi reguler |

Catatan:

- Nomor **`000001`–`000012` tidak ada di repo ini** — disimpan di VPS dan tidak dipublikasikan.
  `000012` adalah `merge_players`; granular live ada di `000013`.
- Folder ini **arsip**, bukan sumber kebenaran. Skema v2 hanya ada di
  [`../../db/migrations`](../../db/migrations); deskripsi lengkapnya di
  [`../handbook/data-model.md`](../handbook/data-model.md).
- Isinya memakai role v1 (`majadu_app`) yang tidak ada di v2. **Jangan apply apa pun dari
  folder ini**, baik ke `bm` maupun `bm2`: `bm` sudah dibekukan sebagai arsip read-only, dan
  `bm2` dimigrasi oleh `dbtools` dari `db/migrations`.

## Peringatan operasional (sejarah v1, tidak berlaku untuk v2)

**000020 memerlukan deploy kode bersamaan.** Setelah dijalankan, API versi
lama akan gagal (masih membaca/menulis kolom yang di-drop). Jalankan migration
tepat setelah deploy API baru; endpoint papan poin (`/rankings`) tidak
terpengaruh karena hanya menyentuh kolom fakta `rating_deltas`.

**Jangan jalankan test integrasi terhadap DB berisi data produksi.**
Beberapa test (`TestIntegrationRatingReadPathAndTransitivity`,
`TestIntegrationAutoIngestLockedSessions`,
`TestIntegrationTeamTournamentRegisterPlayers`) menghitung baris tanpa memfilter
data miliknya sendiri, jadi angka mereka meleset bila DB tidak kosong. Pakai DB
scratch khusus.

**Glicko sudah dipensiunkan (2026-09-29).**
Tidak ada lagi perhitungan rating. `rating_deltas` menyimpan **fakta
pertandingan** saja (`event_id`/`player_id`/`team`/`outcome`) — bahan baku
papan poin BWF. `rating_players` menyimpan **bookkeeping** (`games_played`,
`wins`, `losses`, `last_played_at`). Kelas pemain berasal dari `players.tier`
(sticky), bukan rating.

**`POST /ratings/rebuild-all` butuh pemetaan event→pemain.**
Rebuild menghapus `rating_players` + `rating_deltas` (untuk events dalam musim
saja; deltas musim sebelumnya tidak disentuh), lalu menyusun ulang dari pemetaan
yang dibaca lebih dulu: **rekonstruksi dari sesi** (`sessions` +
`scheduled_games.legacy_order`) sebagai sumber utama, `rating_deltas` sebagai
cadangan. Bila ada event dalam musim tapi kedua sumber itu tidak menghasilkan
pemain sama sekali — deltas kosong DAN sesinya sudah tidak ada — rebuild
**menolak berjalan** (pengaman data-loss), bukan menulis data kosong. Rebuild
juga menyegarkan achievement setelah commit.

**`POST /ratings/replay-all` harus dipakai untuk proses ulang massal.**
Ia menghapus events semua sumber lebih dulu baru meng-ingest menaik kronologis;
replay per-sumber tunggal untuk sumber yang lebih lama akan ditolak pre-check
`ErrOutOfOrder` sebelum ada penghapusan.

