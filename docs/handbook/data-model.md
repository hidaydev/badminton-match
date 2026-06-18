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

Semantics:

- empty string means open slot
- can represent exact pairing or partially specified match

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

- `bm.sessions`
- `bm.tournaments`
- `bm.players`

### Main child entities

- `bm.session_players`
- `bm.fix_matches`
- `bm.scheduled_games`

### Why this shape

Reasons:

- keeps current app behavior stable
- preserves compatibility snapshot contracts
- enables stronger validation and integrity
- allows progressive migration toward a cleaner normalized model
