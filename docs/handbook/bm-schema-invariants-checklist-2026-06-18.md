# BM Schema Invariants Checklist 2026-06-18

Use this as a lightweight operational checklist after important schema changes.

## Aggregate identity

- every `bm.sessions` row has:
  - `id`
  - `share_id`
  - `internal_id`
  - `version > 0`
- every `bm.tournaments` row has:
  - `id`
  - `share_id`
  - `internal_id`
  - `version > 0`

## Session child identity

- every session child row has a valid `session_internal_id`
- `session_id` and `session_internal_id` always resolve to the same aggregate
- uniqueness is enforced on the internal identity path:
  - court index
  - player ref
  - sort order
  - fix match ref
  - scheduled game slot/court

## Domain child identity

- every `session_players` row has `internal_id`
- every `fix_matches` row has `internal_id`
- every `scheduled_games` row has `internal_id`

## Join and extension consistency

- `fix_match_slots` keeps both fix-match identities in sync
- `fix_match_slots` keeps session-player identities in sync when present
- `scheduled_game_players` keeps game and session-player identities in sync
- `game_progress` keeps scheduled-game identities in sync
- `game_scores` keeps scheduled-game identities in sync

## Publish path

- `bm.publish_session(...)` writes successfully with internal-id-first inserts
- `bm.publish_tournament(...)` preserves aggregate identity and version flow

## Snapshot contract

- `bm.get_session_snapshot_compat(...)` returns expected app shape
- parity checks between legacy snapshot and `bm` snapshot still pass when used

## Player resolution

- every canonical player has a matching normalized alias
- no duplicate alias rows exist
- no duplicate session memberships resolve to the same canonical player within one session

## Practical validation set

After major DB changes, verify:

1. `list_sessions`
2. `get_session`
3. `publish_session`
4. `list_players`
5. `get_player_stats`
6. `get_tournament`
7. `publish_tournament`
