# BM Schema Audit 2026-06-18

This document captures the current `bm` schema state after the UUID-first migration and cleanup batches through `20260618_000026_bm_phase_c_uuid_relations_batch_3.sql`.

## Overall assessment

The `bm` schema is now in a strong production-target state for local-first and future production use.

What is already solid:

- Aggregate roots have stable internal UUID identities.
  - `bm.sessions.internal_id`
  - `bm.tournaments.internal_id`
  - `bm.players.id`
- External/share-facing text identifiers are preserved separately.
  - `bm.sessions.id`
  - `bm.sessions.share_id`
  - `bm.tournaments.id`
  - `bm.tournaments.share_id`
- Optimistic concurrency exists on the main mutable aggregates.
  - `bm.sessions.version`
  - `bm.tournaments.version`
- Session and tournament snapshots are validated before publish.
- Runtime app path is already `bm`-first.
- Major session child tables now carry internal UUID identity paths.
- The main session write-path is now internal-id-first.
- Legacy `badminton_match` runtime dependency has been removed.

## What is production-grade enough now

### Aggregate identity

`bm.sessions` and `bm.tournaments` now follow the right pattern:

- internal immutable UUID for database identity
- stable text/share ID for app lookup and URL compatibility
- explicit versioning for concurrent writes

This is a professional shape and aligns with common production practice.

### Write-path safety

`bm.publish_session(...)` and `bm.publish_tournament(...)` now provide:

- fail-fast validation
- conflict detection
- aggregate-level locking
- consistent write orchestration
- internal-id-first child writes in the session publish flow
- stable UUID-first relational paths across active session tables

For this app shape, this is a good production baseline.

### Child identity direction

The following tables now use `internal_id` or internal UUID relation columns as the active path:

- `bm.session_players.internal_id`
- `bm.fix_matches.internal_id`
- `bm.scheduled_games.internal_id`
- `bm.session_courts.session_internal_id`
- `bm.session_players.session_internal_id`
- `bm.fix_matches.session_internal_id`
- `bm.scheduled_games.session_internal_id`
- `bm.fix_match_slots.fix_match_internal_id`
- `bm.fix_match_slots.session_player_internal_id`
- `bm.scheduled_game_players.scheduled_game_internal_id`
- `bm.scheduled_game_players.session_player_internal_id`
- `bm.game_progress.scheduled_game_internal_id`
- `bm.game_scores.scheduled_game_internal_id`

This is now the active end-state for the live schema, not just the direction.

## What is still transitional

At this point the remaining transitional surface is much smaller:

- historical migration files still document the old bigint-led baseline
- compatibility snapshot projection still exists in `bm.get_session_snapshot_compat`
- text app/share IDs still intentionally exist on aggregate roots for lookup and URL stability

The important point is that these are no longer active bigint-led relational dependencies inside the live schema.

## Why the current identity model is no longer “janky”

The schema is no longer integer-led.

It is UUID-led both architecturally and operationally:

- aggregate roots use UUID internal identity
- child/domain entities use UUID primary identity
- join and extension tables also use UUID primary identity
- runtime functions now join through internal UUID relations
- old bigint-led bridge paths have been removed from the live schema

## Remaining risks

### 1. Baseline schema file does not reflect end-state by itself

The original normalized schema migration (`20260617_000003`) still shows the old baseline shape.

That is normal historically, but not ideal for future maintainers because:

- final architecture is spread across many incremental migrations
- understanding the end-state requires reading the migration chain

### 2. Compatibility layers still exist

Functions like:

- `bm.get_session_snapshot_compat`
- legacy migration history referencing `badminton_match`

still exist for compatibility and transition.

This is fine, but it means the codebase still carries historical and projection-oriented surface area.

## Recommended next cleanup backlog

### High priority

1. Freeze the current UUID-first schema state in docs as the canonical live model.
2. Audit whether any remaining compatibility helper can be retired without harming the app contract.
3. Keep the aggregate text/share IDs intentional and documented, not accidental.

### Medium priority

1. Decide whether to keep `get_session_snapshot_compat` as a long-term projection surface or replace it later with a cleaner app contract.
2. Periodically smoke-test `bm.*` only flows after future migrations.

### Documentation priority

1. Produce a canonical “final bm schema” document or snapshot.
2. Mark which migrations were:
   - foundational
   - hardening
   - compatibility
   - UUID transition
   - legacy retirement

## Final verdict

Current `bm` state is good enough to be taken seriously as the main production-target schema.

It is not yet the smallest possible abstraction surface, but it is already:

- structurally coherent
- concurrency-aware
- identity-safe across the full active relational graph
- independent from `badminton_match` at runtime
- independent from `public` wrappers for this app runtime

The remaining work is documentation discipline and selective compatibility cleanup, not schema redesign.
