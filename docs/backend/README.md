# Backend Migrations

SQL migrasi untuk schema PostgreSQL `bm`.

| File | Isi |
|---|---|
| `000013_granular_live.sql` | Granular live ops: `scheduled_games` (per-row OCC `version`), `idempotency_keys`, `outbox_events` |
| `000014_skip_per_game.sql` | Skip per-game (`scheduled_games.skipped_player_refs`) |
| `000015_performance_indexes.sql` | 5 composite/partial index performa |
| `000016_player_achievements.sql` | `player_achievements` |
| `000017_rating_seed.sql` | Benih rating musim: `rating_players.seed_rating/seed_rd/seed_set_at` (disegel `CloseAndStartSeason`) |
| `000018_rank_points.sql` | Ranking poin: `rank_point_levels` + 6 config `rank_*` di `rating_config` |

Catatan:

- Nomor **`000001`–`000012` tidak ada di repo ini** — disimpan di VPS dan tidak dipublikasikan.
  `000012` adalah `merge_players`; granular live ada di `000013`.
- File di folder ini adalah sumber kebenaran untuk migrasi `000013`+; deskripsi skema lengkapnya
  ada di [`../handbook/data-model.md`](../handbook/data-model.md).
- Apply manual via `psql` ke schema `bm`. Tidak ada instance dev terpisah — `bm` adalah satu-satunya DB.

## Peringatan operasional

**Jangan jalankan test integrasi terhadap DB berisi data produksi.**
Beberapa test (`TestIntegrationRatingReadPathAndTransitivity`,
`TestIntegrationAutoIngestLockedSessions`, `TestIntegrationLeaderboard*`,
`TestIntegrationTeamTournamentRegisterPlayers`) menghitung baris tanpa memfilter
data miliknya sendiri, jadi angka mereka meleset bila DB tidak kosong. Pakai DB
scratch khusus.

**`POST /ratings/rebuild-all` menghapus seluruh `rating_deltas`.**
Tabel itu satu-satunya sumber pemetaan event→pemain, dan tidak ada jalur
pemulihan bila isinya hilang. Sejak `RebuildAll` menolak berjalan saat ada event
dalam musim tanpa pemetaan pemain — jangan dilewati pengaman itu.

