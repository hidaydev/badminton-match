# Data Model — Single Source of Truth

Dokumen ini adalah **sumber kebenaran tunggal (*Single Source of Truth*)** untuk seluruh desain data model aplikasi Majadu, mencakup TypeScript domain types (Frontend) dan PostgreSQL relational schema (Backend `apps/api`).

> **Batas verifikasi (2026-11-03).** Bagian TypeScript bersumber dari kode `apps/web`.
> Untuk PostgreSQL: migrasi baseline `000001`–`000012` (tabel inti `sessions`, `players`,
> `player_aliases`, `session_players`, `scheduled_games`, `scheduled_game_players`,
> `rating_events`/`rating_deltas`/`rating_config`, termasuk PK/FK/UNIQUE/trigger)
> **tidak ada di repo** — hanya diarsipkan di VPS. Karena itu isi §4 di bawah
> terverifikasi dari migrasi `000013`–`000023` di [`docs/backend/`](../backend/) plus
> query di `apps/api/internal/store/`; constraint baseline di §5 adalah asumsi yang
> belum bisa diperiksa dari repo.

---

## 📱 1. Core Session Model (Frontend TS Types)

Main source: `apps/web/src/types/index.ts`

### Player
Fields:
- `id`: Local session-app player ID (mis. `"p1"`, `"p2"`)
- `name`: Display name
- `gender`: `'M'` | `'F'` (canonical)
- `tier`: `1`–`8` (D=1, D+=2, C=3, C+=4, B=5, B+=6, A=7, A+=8 — 8-tier unified)

*Catatan:* `tier` bersifat "first-set sticky", disimpan secara kanonikal di tabel backend `players`.

### FixMatch (kode: `MatchConstraint`)

Fields:
- `id`: Constraint ID
- `slots`: `[PlayerId, PlayerId, PlayerId, PlayerId]` (string kosong = bebas)
- `mode`: `'flexible'` | `'pinned'`
- `pinnedTime`: `TimeString` `HH:MM` (wajib untuk `mode: 'pinned'`)
- `pinnedCourt`: Index lapangan (0-based, wajib untuk `mode: 'pinned'`)

### ScheduleSlot & GameScore
- `ScheduleSlot`: Atomic scheduled game unit (`slot`, `court`, `teamA: [p1, p2]`, `teamB: [p3, p4]`).
- `GameScore`: Score object (`a: number`, `b: number`) di-key secara eksternal via `${slot}-${court}`.

### SessionConfig
Fields:
- `title`, `date`, `courts`, `sessionStart`, `slotMinutes`, `courtTimes`, `playerCount`, `courtNames`, `locked`

---

## ☁️ 2. Cloud & Shared Snapshot Models

Main sources: `apps/web/src/types/index.ts` (definisi `CloudSnapshot`; di-re-export `apps/web/src/queries/types.ts`) & `apps/web/src/utils/shareUrl.ts`

### CloudSnapshot
Payload operasional untuk publikasi & sinkronisasi sesi ke cloud:
- `version`?: Optimistic concurrency version
- `session`: `SessionConfig`
- `players`: Array of `Player`
- `fixMatches`: Array of `MatchConstraint`
- `schedule`: Array of `ScheduleSlot`
- `playedGames`: `string[]` — daftar key `${slot}-${court}` yang sudah dimainkan
- `gameScores`: Record of `${slot}-${court}` -> `GameScore`
- `absentPlayers`?: Array of player IDs (absent players)
- `skippedPlayers`?: Record of `${slot}-${court}` -> array player ref yang di-skip

---

## 🏆 3. Tournament Models

Main sources: `apps/web/src/utils/tournament.ts` & `apps/web/src/utils/teamTournament.ts`

### Classic Tournament
- `TournamentPair`: `id`, `name`
- `TournamentMatch`: `id`, `phase`, `groupId`?, `pairAId`, `pairBId`, `scoreA`, `scoreB`, `picName`?
- `TournamentSnapshot`: `name`, `date`, `pairs`, `groups`, `matches`

### Team Tournament
- `TeamInfo`: `id` (`t1`–`t6`), `name`, `players: TeamPlayer[]`
- `TeamPlayer`: `name`, `cls: TeamClass` (`'A+'` | `'A'` | `'B+'` | `'B'` | `'C+'` | `'C'`)
- `TeamMatch`: `id` (`"g-1"`–`"g-9"`, `"final"`), `phase`, `teamA`, `teamB`, `partai: TeamPartai[]` (3 doubles)
- `TeamTournamentSnapshot`: `format: 'team'`, `name`, `date`, `teams`, `matches`

---

## 🗄️ 4. Backend Persistence Model (PostgreSQL `bm`)

Backend: Go (`majadu-api`) terhubung langsung ke PostgreSQL VPS pada schema `bm` (production).

### Resolusi Nama (snapshot vs canonical)

- `session_players.source_name` dan `tournament_team_players.player_name` adalah **snapshot** nama
  saat sesi/turnamen dibuat. Nilainya ikut `SourceFingerprint` / `MatchKey`, jadi **tidak boleh
  dimutasi** oleh rename — kalau berubah, sesi lama dianggap berubah sumbernya (`ErrSourceChanged`).
- Nama yang ditampilkan di-resolve dari `players.canonical_name` bila pemain terdaftar:
  `COALESCE(p.canonical_name, sp.source_name)` di read-path sesi, dan
  `COALESCE(p.canonical_name, ttp.player_name)` di read-path team tournament.
  Placeholder (pemain tanpa `player_id`) tetap memakai snapshot.
- `RenamePlayer` hanya memperbarui `players.canonical_name`, `player_aliases`, dan
  `tournament_pairs.pair_name` (classic tournament).

### Main Tables & Identity

- `sessions`: Session aggregate metadata dengan `id` (UUID PK), `share_code` (`s+10alnum` UNIQUE), `version` (int), `status` (`'draft'` | `'locked'`), `session_date`.
- `tournaments`: Tournament aggregate metadata dengan `id` (UUID PK), `share_code`, `name`, `event_date`, `format` (`'classic'` | `'team'`), `version`.
- `players`: Canonical player records (UUID PK, `canonical_name` UNIQUE, `gender`, `tier` 1–8, `registered_at`).
- `player_aliases`: Normalized `alias_name` (lowercase PK) -> `player_id` UUID FK untuk pencocokan nama fuzzy & TOCTOU-safe registration.

### Granular & Concurrency Tables (Migration `000013`)

- `scheduled_games`: Game unit per slot/court dengan `version` (BIGINT per-row OCC), `is_played`, `score_a`, `score_b`, `skipped_player_refs`.
- `idempotency_keys`: `(session_id, key)` PK dengan `response` JSONB & `expires_at` TTL persistent.
- `outbox_events`: Durable event log untuk SSE stream & event catch-up.

### Player Achievements (Migration `000016`)

- `player_achievements`: satu baris = satu achievement per pemain. `achievement_key` UNIQUE per
  `player_id` (identitas + idempotency); `kind` ∈ `attendance`, `volume`, `opponent`, `tournament`,
  `tier`, `rating`, `rank`, `social`, `season` (CHECK `000016:24-27`). Yang benar-benar ditulis
  kode hanya `attendance`/`volume`/`opponent`/`tournament`/`social`/`rank`
  (`domain/achievements.go:48-58`, `store/achievement.go:577`); `tier`/`rating`/`season` tinggal
  nilai CHECK yang tak pernah dipakai sejak Glicko pensiun;
  `value` untuk achievement tipe rekor; `earned_at` tidak berubah walau rekor naik; `meta` JSONB.
  Kolom `season_id` + FK-nya di-drop `000020`.
- Index: `idx_player_achievements_player(player_id, earned_at DESC)`, `idx_player_achievements_kind(kind)`.
- Definisi & ambang achievement: `apps/api/internal/domain/achievements.go` dan
  `apps/web/src/config/achievements.ts`.

### Performance Indexes (Migration `000015`)

1. `idx_rating_players_active`: Partial index `rating_players(games_played, last_played_at) WHERE games_played > 0`
2. `idx_rating_deltas_player_event`: Composite index `rating_deltas(player_id, event_id)`
3. `idx_rating_events_sort_lookup`: Sort index `rating_events(id, date DESC, created_at DESC, source_id DESC, game_order DESC)`
4. `idx_session_players_session_player`: Composite index `session_players(session_id, player_id)`
5. `idx_scheduled_games_session`: Foreign key index `scheduled_games(session_id)`

### Papan Poin Ranking (Migrasi `000018`–`000023`)

Mesin Glicko dipensiunkan 2026-09-29 (`000020_purge_glicko.sql`): tidak ada lagi
perhitungan rating. Papan publik memakai **poin** — window bergulir 12 minggu, 10 entri
terbaik — dan dihitung **saat baca** (tidak ada tabel materialized).

- `rating_config`: JSONB key-value. Key yang dibaca loader
  (`apps/api/internal/store/rating_config.go`): `ingest_locked_only`, `auto_reconcile`,
  `absent_policy`, `placeholder_promote_games`, `season_start`, `session_tier_init`,
  `class_bands`, plus `rank_window_weeks`, `rank_best_n`, `rank_opponent_weight`,
  `rank_opponent_clamp`, `rank_session_base`, `rank_thin_evidence_n`, `rank_min_sessions`.
- `rating_players`: bookkeeping pertandingan — `games_played`, `wins`, `losses`,
  `last_played_at` (`rating`, `rd`, `peak_rating`, `seed_*` di-drop `000020`).
- `rating_events`: satu baris per pertandingan ter-ingest. Kolom yang dipakai kode:
  `match_key` (UNIQUE), `kind`, `source_id` (share_code sesi/turnamen),
  `source_fingerprint`, `stable_game_id`, `date`, `game_order`, `title`, `score_a`,
  `score_b`, `target`, `phase`, `processed_at`.
- `rating_deltas`: fakta per pemain — `event_id`, `player_id`, `team`, `outcome`.
  Kolom angka Glicko (`expected`, `movm`, `delta`, `new_rating`) di-drop `000020`.
- `rating_sources`: fingerprint sumber yang sudah ter-ingest — `source_id` (PK),
  `source_kind`, `fingerprint`, `finalized`, `last_ingested_seq`, `ingested_at`.
- `rank_point_levels` (`000018`): semua nilai poin di satu tabel — `kind` (PK: `session`,
  `tournament_classic`, `tournament_team`), `champion_points`, `round_ratios` JSONB,
  `enabled`.
- `rank_snapshots` (`000019`): posisi papan per tanggal acuan — PK `(as_of, player_id)`,
  `rank`, `points`, `captured_at`; dasar panah naik/turun di papan.

Tabel musim (`rating_seasons`, `season_player_snapshots`) sudah di-drop `000020`.

---

## 🔒 5. Key Constraints & Rules

- `players.tier`: CHECK (tier BETWEEN 1 AND 8) — 8-tier unified (D..A+).
- `players.gender`: CHECK (gender IN ('M', 'F')), NOT NULL, DEFAULT 'M'.
- `player_aliases.alias_name`: LOWERCASE UNIQUE PK.
- `session_players`: UNIQUE (session_id, player_id).
- `player_achievements`: UNIQUE (player_id, achievement_key); `player_id` ON DELETE CASCADE.
  (Kolom `season_id` + FK `ON DELETE SET NULL` di-drop `000020`.)
