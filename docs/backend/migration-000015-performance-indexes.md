# Migration 000015: PostgreSQL Performance Indexes

**Tanggal:** 2026-09-10  
**Tujuan:** Mengoptimalkan performa query leaderboard, LATERAL join rating deltas, serta foreign key lookup pada `session_players` dan `scheduled_games`.

---

## 📌 Index yang Ditambahkan

1. `idx_rating_players_active`: Partial index pada `rating_players(games_played, last_played_at) WHERE games_played > 0` untuk query `RatingLeaderboard` filter 90 hari.
2. `idx_rating_deltas_player_event`: Composite index pada `rating_deltas(player_id, event_id)` untuk mempercepat `LATERAL JOIN` per pemain.
3. `idx_rating_events_sort_lookup`: Index pengurutan `rating_events(id, date DESC, created_at DESC, source_id DESC, game_order DESC)`.
4. `idx_session_players_session_player`: Composite index `session_players(session_id, player_id)`.
5. `idx_scheduled_games_session`: Index lookup `scheduled_games(session_id)`.

---

## 🧪 Cara Eksekusi

```bash
# Apply ke database prod (bm)
podman exec -i qouver-postgres psql -U qouver -d bm < docs/backend/000015_performance_indexes.sql

# Apply ke database dev (bm_dev)
podman exec -i qouver-postgres psql -U qouver -d bm_dev < sed 's/bm\./bm_dev\./g' docs/backend/000015_performance_indexes.sql
```
