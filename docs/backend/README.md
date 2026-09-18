# Backend Migrations

SQL migrasi untuk schema PostgreSQL `bm`.

| File | Isi |
|---|---|
| `000013_granular_live.sql` | Granular live ops: `scheduled_games` (per-row OCC `version`), `idempotency_keys`, `outbox_events` |
| `000014_skip_per_game.sql` | Skip per-game (`scheduled_games.skipped_player_refs`) |
| `000015_performance_indexes.sql` | 5 composite/partial index performa |
| `000016_player_achievements.sql` | `player_achievements` |

Catatan:

- Nomor **`000001`–`000012` tidak ada di repo ini** — disimpan di VPS dan tidak dipublikasikan.
  `000012` adalah `merge_players`; granular live ada di `000013`.
- File di folder ini adalah sumber kebenaran untuk migrasi `000013`+; deskripsi skema lengkapnya
  ada di [`../handbook/data-model.md`](../handbook/data-model.md).
- Apply manual via `psql` ke schema `bm`. Tidak ada instance dev terpisah — `bm` adalah satu-satunya DB.
