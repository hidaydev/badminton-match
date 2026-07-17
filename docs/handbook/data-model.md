# Data Model

## Core session model

Main source:

- `src/store/index.ts`

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
- `slotsPerCourt`
- `totalGames`
- `courtNames`
- `locked`

This is the main configuration model for session generation.

## Cloud snapshot model

Main source:

- `src/queries/types.ts`

### CloudSnapshot

Fields:

- `session`
- `players`
- `fixMatches`
- `schedule`
- `playedGames`
- `gameScores`
- optional `absentPlayers`
- optional `locked`

Notes:

- `locked` when `true` causes `publish_session` to reject all subsequent writes
- `locked` is set via the lock session feature in the UI
- unlock is admin-only via `bm.unlock_session` RPC (service_role only)
- `delete_session` also rejects deletion of non-draft (locked) sessions
- `unlock_session` bumps the version when resetting to draft

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

Current main runtime schema:

1. `bm`

Current approach is aggregate-root plus normalized relational support:

- sessions and tournaments still preserve snapshot-style contracts for app compatibility
- relational child tables support indexing, stats, integrity, and future evolution

### Main aggregate roots

- `bm.sessions` — session metadata with `version` (optimistic concurrency), `status` (draft/locked/published), `internal_id` (UUID), `share_id`
- `bm.tournaments` — tournament snapshots with `version` and `snapshot` (JSONB)
- `bm.players` — canonical player records (UUID PK, canonical_name)
- `bm.player_aliases` — normalized name → player_id mapping for fuzzy resolution

### Main child entities

- `bm.session_players` — player roster per session (with gender, tier, sort order, absent status)
- `bm.session_courts` — per-court time ranges and names
- `bm.fix_matches` — pre-assigned match constraints per session
- `bm.fix_match_slots` — individual slot assignments within fix matches
- `bm.scheduled_games` — generated/scheduled games (slot, court, status, source)
- `bm.scheduled_game_players` — team/position assignments per scheduled game
- `bm.game_progress` — played status and order per game
- `bm.game_scores` — score (A/B) per game

### Why this shape

Reasons:

- keeps current app behavior stable
- preserves compatibility snapshot contracts
- enables stronger validation and integrity
- allows progressive migration toward a cleaner normalized model
