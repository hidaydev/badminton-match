# Data Model

## Core session model

Main source:

- `src/types/index.ts`

### Player

Fields:

- `id`
- `name`
- `gender` ('M' | 'F')
- `tier` (1–8: D=1, D+=2, C=3, C+=4, B=5, B+=6, A=7, A+=8)

Notes:

- player ids are session-app local ids (not backend UUIDs)
- tier is "first-set sticky" — canonical tier stored in backend `players` table
- gender is stored canonically in backend `players` table

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

### Classic Tournament

Main source:

- `src/utils/tournament.ts`

#### TournamentPair

Fields:

- `id`
- `name`

#### TournamentMatch

Fields:

- `id`
- `phase`
- optional `groupId`
- `pairAId`
- `pairBId`
- `scoreA`
- `scoreB`
- optional `picName`

#### TournamentSnapshot

Fields:

- `name`
- `date`
- `pairs`
- `groups`
- `matches`

### Team Tournament

Main source:

- `src/utils/teamTournament.ts`

#### TeamInfo

Fields:

- `id` (t1–t6)
- `name`
- `players: TeamPlayer[]`

#### TeamPlayer

Fields:

- `name`
- `cls: TeamClass` ('A+' | 'A' | 'B+' | 'B' | 'C+' | 'C')

#### TeamMatch

Fields:

- `id` ("g-1"–"g-9" or "final")
- `phase: 'group' | 'final'`
- `teamA` (team id)
- `teamB` (team id)
- `partai: TeamPartai[]` (3 doubles matches per team-match)

#### TeamTournamentSnapshot

Fields:

- `format: 'team'`
- `name`
- `date`
- `teams: TeamInfo[]`
- `matches: TeamMatch[]`

## Backend persistence model (PostgreSQL on VPS)

> Backend: Go (`majadu-api` repo) — langsung akses Postgres, tanpa PostgREST/RPC.
> Migrasi: 000001–000011 (disimpan di VPS: `/srv/qouver/majadu/migrations/`).

Schema: `bm` (prod) / `bm_dev` (dev)

Current approach: aggregate-root plus normalized relational support

### Main aggregate roots

- `sessions` — session metadata with `version` (optimistic concurrency), `status` (draft/locked/published), `id` (UUID), `share_code`
- `tournaments` — tournament snapshots with `version`
- `players` — canonical player records (UUID PK, canonical_name, gender, tier, registered_at)
- `player_aliases` — normalized name → player_id mapping for fuzzy resolution

### Rating tables

- `rating_config` — JSONB key-value store (season_start, decay parameters, class_bands, session_tier_init)
- `rating_players` — per-player rating state (rating, rd, peak_rating, games_played, wins, losses)
- `rating_events` — match-level events (source_id, date, score_a, score_b, team compositions)
- `rating_deltas` — per-player rating changes per event (old/new rating, rd, delta)
- `rating_sources` — session/tournament source tracking (session_id, fingerprint, processed_at)
- `season_player_snapshots` — end-of-season player snapshots

### Main child entities

- `session_players` — player roster per session (with gender, tier, sort order, absent status)
- `session_courts` — per-court time ranges and names
- `fix_matches` — pre-assigned match constraints per session
- `fix_match_slots` — individual slot assignments per fix match
- `scheduled_games` — generated/scheduled games (slot, court, status, source)
- `scheduled_game_players` — team/position assignments per scheduled game
- `tournament_pairs` / `tournament_pair_players` / `tournament_groups` / `tournament_matches` — classic tournament structure
- `tournament_team_players` — team tournament player assignments

### Key constraints

- `players.tier` CHECK: 8-tier (D, D+, C, C+, B, B+, A, A+)
- `players.gender` CHECK: (M, F), NOT NULL, DEFAULT 'M'
- `player_aliases.alias_name` UNIQUE
- `session_players` UNIQUE: (session_id, player_id)
