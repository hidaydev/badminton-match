# Data Model

## Core session model

Main source:

- `src/types/index.ts`

### Player

Fields:

- `id`
- `name`
- `gender`
- `tier`

Notes:

- player ids are session-app local ids
- they are not the same as `MDEF` canonical player ids

### FixMatch

Fields:

- `id`
- `slots: [string, string, string, string]`
- `mode: 'flexible' | 'pinned'`
- optional `pinnedTime` (HH:MM format)
- optional `pinnedCourt` (0-based court index)

Semantics:

- empty string means open slot
- can represent exact pairing or partially specified match
- `pinned` mode: match is locked to specific time and court
- `flexible` mode: generator decides placement

### ScheduleSlot

Fields:

- `slot`
- `court`
- `teamA`
- `teamB`

This is the atomic scheduled game unit.

### GameScore

Fields:

- `a`
- `b`

Scores are keyed externally by:

- `${slot}-${court}`

### SessionConfig

Fields:

- `title`
- `date`
- `courts`
- `sessionStart`
- `slotMinutes`
- `courtTimes`
- `playerCount`
- `courtNames`
- `locked`

This is the main configuration model for session generation.

## Cloud snapshot model

Main source:

- `src/queries/types.ts`

### CloudSnapshot

Fields:

- optional `version`
- `session`
- `players`
- `fixMatches`
- `schedule`
- `playedGames`
- `gameScores`
- optional `absentPlayers`

Notes:

- `version` enables optimistic concurrency on publish
- `locked` is a field on the nested `session` (SessionConfig), not on CloudSnapshot directly
- saat `session.locked` true, write-path Go set status session ke `'locked'`
- unlock: `POST /sessions/{id}/unlock` (Go) — status → `draft`, version +1
- `DELETE /sessions/{id}` juga menolak hapus session non-draft (locked)

This is the operational persisted payload for published sessions.

It is also the safest short-term handoff format for external consumers like
`MDEF`.

## Shared-view snapshot model

Main source:

- `src/utils/shareUrl.ts`

### SharedSnapshot

Fields:

- `sessionId`
- `session`
- `players`
- `schedule`
- `lastResult`

This is a compressed, hash-based view payload used for local share/view mode.
It is separate from the cloud session model.

## Tournament model

Main source:

- `src/utils/tournament.ts`

### TournamentPair

Fields:

- `id`
- `name`

### TournamentMatch

Fields:

- `id`
- `phase`
- optional `groupId`
- `pairAId`
- `pairBId`
- `scoreA`
- `scoreB`
- optional `picName`

### TournamentSnapshot

Fields:

- `name`
- `date`
- `pairs`
- `groups`
- `matches`

## Supabase persistence model

> 2026-08-15: Supabase sudah pensiun. Persistensi sekarang = Postgres VPS
> (schema `bm` prod / `bm_dev` dev) yang diakses **langsung oleh backend Go
> (`majadu-api`)** — tidak ada PostgREST/RPC. Definisi schema & migrasi:
> `majadu-api/migrations/` (000001–000005). Referensi era Supabase: git history.

Current runtime schema:

1. `bm` (prod) / `bm_dev` (dev)

Current approach is aggregate-root plus normalized relational support:

- sessions and tournaments still preserve snapshot-style contracts for app compatibility
- relational child tables support indexing, stats, integrity, and future evolution

### Main aggregate roots

- `sessions` — session metadata with `version` (optimistic concurrency), `status` (draft/locked/published), `id` (UUID), `share_code`
- `tournaments` — tournament snapshots with `version`
- `players` — canonical player records (UUID PK, canonical_name)
- `player_aliases` — normalized name → player_id mapping for fuzzy resolution

### Main child entities

- `session_players` — player roster per session (with gender, tier, sort order, absent status)
- `session_courts` — per-court time ranges and names
- `fix_matches` — pre-assigned match constraints per session
- `scheduled_games` — generated/scheduled games (slot, court, status, source)
- `scheduled_game_players` — team/position assignments per scheduled game
- `tournament_pairs` / `tournament_pair_players` / `tournament_groups` / `tournament_matches` — tournament structure

Semua logika bisnis (validasi, version concurrency, lock, resolve alias) dijalankan
di Go (`majadu-api/internal/`), bukan fungsi SQL. Sisa fungsi SQL di DB hanya
`normalize_player_name` (CHECK constraint `player_aliases`) + utilitas.
