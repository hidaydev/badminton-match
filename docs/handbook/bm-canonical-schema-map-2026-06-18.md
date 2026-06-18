# BM Canonical Schema Map 2026-06-18

This document is the easiest way to understand the current `bm` schema without replaying the full migration chain.

## Identity model

### Aggregate roots

These are the main domain anchors:

- `bm.players`
  - primary identity: `id uuid`
- `bm.sessions`
  - aggregate identity: `internal_id uuid`
  - external/share identity: `id text`, `share_id text`
- `bm.tournaments`
  - aggregate identity: `internal_id uuid`
  - external/share identity: `id text`, `share_id text`

### Domain child entities

These are important entities inside the session aggregate:

- `bm.session_players`
  - legacy PK: `id bigserial`
  - internal identity: `internal_id uuid`
  - aggregate link: `session_internal_id uuid`
- `bm.fix_matches`
  - legacy PK: `id bigserial`
  - internal identity: `internal_id uuid`
  - aggregate link: `session_internal_id uuid`
- `bm.scheduled_games`
  - legacy PK: `id bigserial`
  - internal identity: `internal_id uuid`
  - aggregate link: `session_internal_id uuid`

### Join and extension tables

These are mostly structural carriers, not primary domain anchors:

- `bm.session_courts`
- `bm.fix_match_slots`
- `bm.scheduled_game_players`
- `bm.game_progress`
- `bm.game_scores`

They already carry internal relation columns where needed.

## Table map

### `bm.players`

Purpose:

- canonical player registry

Important columns:

- `id uuid`
- `canonical_name text`

Important rules:

- canonical name is unique

### `bm.player_aliases`

Purpose:

- normalized alias resolution into canonical players

Important columns:

- `alias_name text`
- `player_id uuid`

Important rules:

- alias name is normalized
- one alias resolves to one player

### `bm.sessions`

Purpose:

- session aggregate root

Primary identity:

- `internal_id uuid`

External identity:

- `id text`
- `share_id text`

Important columns:

- title/date/start/time config
- source/status
- `version`

Important rules:

- `internal_id` unique
- `share_id` unique
- optimistic concurrency via `version`

### `bm.session_courts`

Purpose:

- per-session court/time configuration

Primary current carrier:

- `id bigserial`

Aggregate relation:

- `session_internal_id uuid`

Important rules:

- one row per `(session_internal_id, court_index)`

### `bm.session_players`

Purpose:

- player membership within a session

Primary current identity:

- `internal_id uuid`

Legacy carrier:

- `id bigserial`

Aggregate relation:

- `session_internal_id uuid`

Important rules:

- unique by `(session_internal_id, player_id)`
- unique by `(session_internal_id, player_ref)`
- unique by `(session_internal_id, sort_order)`

### `bm.fix_matches`

Purpose:

- fixed/manual match constraints inside a session

Primary current identity:

- `internal_id uuid`

Legacy carrier:

- `id bigserial`

Aggregate relation:

- `session_internal_id uuid`

Important rules:

- unique by `(session_internal_id, legacy_ref)`
- unique by `(session_internal_id, sort_order)`

### `bm.fix_match_slots`

Purpose:

- slot assignments inside a fixed match

Relations:

- `fix_match_internal_id uuid`
- optional `session_player_internal_id uuid`

Legacy carriers:

- `fix_match_id bigint`
- `session_player_id bigint`

Important rules:

- unique by `(fix_match_internal_id, slot_index)`

### `bm.scheduled_games`

Purpose:

- scheduled game entities within a session

Primary current identity:

- `internal_id uuid`

Legacy carrier:

- `id bigserial`

Aggregate relation:

- `session_internal_id uuid`

Important rules:

- unique by `(session_internal_id, slot_index, court_index)`
- unique by `(session_internal_id, legacy_order)`

### `bm.scheduled_game_players`

Purpose:

- team membership rows for each scheduled game

Relations:

- `scheduled_game_internal_id uuid`
- `session_player_internal_id uuid`

Legacy carriers:

- `scheduled_game_id bigint`
- `session_player_id bigint`

Important rules:

- unique by `(scheduled_game_internal_id, team, position)`
- unique by `(scheduled_game_internal_id, session_player_internal_id)`

### `bm.game_progress`

Purpose:

- one-to-one progress extension for a scheduled game

Primary current relation:

- `scheduled_game_internal_id uuid`

Legacy carrier:

- `scheduled_game_id bigint`

Important rules:

- one row per scheduled game

### `bm.game_scores`

Purpose:

- one-to-one score extension for a scheduled game

Primary current relation:

- `scheduled_game_internal_id uuid`

Legacy carrier:

- `scheduled_game_id bigint`

Important rules:

- one row per scheduled game
- score cannot be tied

### `bm.tournaments`

Purpose:

- tournament aggregate root

Primary identity:

- `internal_id uuid`

External identity:

- `id text`
- `share_id text`

Important rules:

- `internal_id` unique
- `share_id` unique
- optimistic concurrency via `version`

## Active function map

### Aggregate reads

- `bm.get_session(text)`
- `bm.get_tournament(text)`
- `bm.list_sessions()`
- `bm.list_players()`
- `bm.get_player_stats(text)`

### Aggregate writes

- `bm.publish_session(text, jsonb, text)`
- `bm.publish_tournament(text, jsonb)`

### Compatibility helpers

- `bm.get_session_snapshot_compat(text)`
- public RPC wrappers that forward into `bm`

## Transitional columns

These still exist intentionally:

- legacy bigint PK/FK columns on child and join tables
- text ids on session/tournament aggregates

Why they still exist:

- compatibility
- incremental migration safety
- easier local and future production rollout

## Practical mental model

Use this model:

1. `sessions`, `tournaments`, and `players` are real roots.
2. `session_players`, `fix_matches`, and `scheduled_games` are real child entities.
3. everything else is structural support around those entities.
4. internal UUID identity is the architectural source of truth.
5. legacy bigint/text identity paths are still present, but no longer lead the design.
