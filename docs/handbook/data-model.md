# Data Model — Single Source of Truth

Dokumen ini adalah **sumber kebenaran tunggal (*Single Source of Truth*)** untuk seluruh desain data model aplikasi Majadu, mencakup TypeScript domain types (Frontend) dan PostgreSQL relational schema (Backend `apps/api`).

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

### FixMatch
Fields:
- `id`: Constraint ID
- `slots`: `[string, string, string, string]`
- `mode`: `'flexible'` | `'pinned'`
- `pinnedTime`?: String `HH:MM`
- `pinnedCourt`?: Index lapangan (0-based)

### ScheduleSlot & GameScore
- `ScheduleSlot`: Atomic scheduled game unit (`slot`, `court`, `teamA: [p1, p2]`, `teamB: [p3, p4]`).
- `GameScore`: Score object (`a: number`, `b: number`) di-key secara eksternal via `${slot}-${court}`.

### SessionConfig
Fields:
- `title`, `date`, `courts`, `sessionStart`, `slotMinutes`, `courtTimes`, `playerCount`, `courtNames`, `locked`

---

## ☁️ 2. Cloud & Shared Snapshot Models

Main sources: `apps/web/src/queries/types.ts` & `apps/web/src/utils/shareUrl.ts`

### CloudSnapshot
Payload operasional untuk publikasi & sinkronisasi sesi ke cloud:
- `version`?: Optimistic concurrency version
- `session`: `SessionConfig`
- `players`: Array of `Player`
- `fixMatches`: Array of `FixMatch`
- `schedule`: Array of `ScheduleSlot`
- `playedGames`: Record of `${slot}-${court}` -> boolean
- `gameScores`: Record of `${slot}-${court}` -> `GameScore`
- `absentPlayers`?: Array of player IDs (absent players)

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

### Main Tables & Identity

- `sessions`: Session aggregate metadata dengan `id` (UUID PK), `share_code` (`s+10alnum` UNIQUE), `version` (int), `status` (`'draft'` | `'locked'`), `session_date`.
- `tournaments`: Tournament aggregate metadata dengan `id` (UUID PK), `share_code`, `name`, `event_date`, `format` (`'classic'` | `'team'`), `version`.
- `players`: Canonical player records (UUID PK, `canonical_name` UNIQUE, `gender`, `tier` 1–8, `registered_at`).
- `player_aliases`: Normalized `alias_name` (lowercase PK) -> `player_id` UUID FK untuk pencocokan nama fuzzy & TOCTOU-safe registration.

### Granular & Concurrency Tables (Migration `000013`)

- `scheduled_games`: Game unit per slot/court dengan `version` (BIGINT per-row OCC), `is_played`, `score_a`, `score_b`, `skipped_player_refs`.
- `idempotency_keys`: `(session_id, key)` PK dengan `response` JSONB & `expires_at` TTL persistent.
- `outbox_events`: Durable event log untuk SSE stream & event catch-up.

### Performance Indexes (Migration `000015`)

1. `idx_rating_players_active`: Partial index `rating_players(games_played, last_played_at) WHERE games_played > 0`
2. `idx_rating_deltas_player_event`: Composite index `rating_deltas(player_id, event_id)`
3. `idx_rating_events_sort_lookup`: Sort index `rating_events(id, date DESC, created_at DESC, source_id DESC, game_order DESC)`
4. `idx_session_players_session_player`: Composite index `session_players(session_id, player_id)`
5. `idx_scheduled_games_session`: Foreign key index `scheduled_games(session_id)`

### Rating Engine Tables

- `rating_config`: JSONB key-value configuration (`season_start`, `session_tier_init`, `class_bands`)
- `rating_players`: State rating pemain (`rating`, `rd`, `peak_rating`, `games_played`, `wins`, `losses`, `last_played_at`)
- `rating_events`: Match-level Glicko event log (`source_id`, `date`, `score_a`, `score_b`, `teams`)
- `rating_deltas`: Per-player rating change (`old_rating`, `new_rating`, `rd`, `delta`)
- `rating_sources`: Tracking fingerprint sesi/turnamen yang sudah ter-ingest (`source_id`, `processed_at`)
- `season_player_snapshots`: Snapshot rating akhir musim saat season close.

---

## 🔒 5. Key Constraints & Rules

- `players.tier`: CHECK (tier BETWEEN 1 AND 8) — 8-tier unified (D..A+).
- `players.gender`: CHECK (gender IN ('M', 'F')), NOT NULL, DEFAULT 'M'.
- `player_aliases.alias_name`: LOWERCASE UNIQUE PK.
- `session_players`: UNIQUE (session_id, player_id).
