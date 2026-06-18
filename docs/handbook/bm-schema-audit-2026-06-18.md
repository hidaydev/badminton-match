# BM Schema Audit 2026-06-18

This document captures the current `bm` schema state after the UUID-first migration batches through `20260618_000021_bm_phase_b_identity_consistency.sql`.

## Overall assessment

The `bm` schema is now in a strong transitional-to-production state for local-first and future production use.

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

For this app shape, this is a good production baseline.

### Child identity direction

The following tables now carry `internal_id` or internal UUID relation columns:

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

This is the right direction and removes the previous over-reliance on text and serial IDs.

## What is still transitional

### Legacy numeric primary keys still exist in many child tables

These are still present:

- `bm.session_courts.id bigserial`
- `bm.session_players.id bigserial`
- `bm.fix_matches.id bigserial`
- `bm.fix_match_slots.id bigserial`
- `bm.scheduled_games.id bigserial`
- `bm.scheduled_game_players.id bigserial`
- `bm.game_progress.scheduled_game_id bigint primary key`
- `bm.game_scores.scheduled_game_id bigint primary key`

This is not automatically bad.

Current judgment:

- acceptable for internal-only relational carriers
- not ideal as long-term primary identity for externally meaningful domain objects

The important distinction is:

- `session_players`, `fix_matches`, and `scheduled_games` are now domain entities with UUID internal IDs too
- the remaining bigint PKs are mostly legacy join carriers and compatibility scaffolding

### Some tables still have dual identity paths

Several child tables still carry both:

- old bigint FK path
- new UUID/internal FK path

That is acceptable during migration, but not ideal forever because:

- it increases schema surface area
- it duplicates consistency responsibilities
- it makes future maintenance noisier

`20260618_000021` improves this materially by enforcing identity consistency via composite FKs.

## Why the current integer usage is not “janky”

The remaining integers are not a design smell by themselves.

They are acceptable when:

- they stay internal
- they are not used as user-facing identifiers
- they are not the only trustworthy domain identity
- the schema also has stronger immutable identity for important entities

That is now mostly true for `bm`.

So the schema is no longer “integer-led”.
It is now UUID-led at the architectural level, even if some legacy bigint columns remain.

## Remaining risks

### 1. Dual-key maintenance complexity

The schema still needs both:

- old relational bigint links
- new UUID/internal links

Risk:

- future writes could accidentally update only one path unless guardrails stay complete

Mitigation already in place:

- backfills
- internal FK columns
- composite identity constraints in later batches
- read/write function migration toward UUID-first joins

### 2. Baseline schema file does not reflect end-state by itself

The original normalized schema migration (`20260617_000003`) still shows the old baseline shape.

That is normal historically, but not ideal for future maintainers because:

- final architecture is spread across many incremental migrations
- understanding the end-state requires reading the migration chain

### 3. Compatibility layers still exist

Functions like:

- `bm.get_session_snapshot_compat`
- old wrapper surfaces in `public`
- legacy migration history referencing `badminton_match`

still exist for compatibility and transition.

This is fine for now, but it means the codebase is not yet at a “single final abstraction only” state.

## Recommended next cleanup backlog

### High priority

1. Keep moving active reads and writes to internal-ID-first joins.
2. Ensure all child-table write paths populate UUID/internal relation columns by default.
3. Keep composite consistency constraints anywhere a row stores both old and new identity references.

### Medium priority

1. Decide whether `fix_match_slots` and `scheduled_game_players` should get their own `internal_id uuid`.
2. Decide whether `game_progress` and `game_scores` should eventually use:
   - a dedicated UUID PK
   - or continue as one-to-one extension tables keyed by scheduled game

### Documentation priority

1. Produce a canonical “final bm schema” document or snapshot.
2. Mark which migrations were:
   - foundational
   - hardening
   - compatibility
   - UUID transition

## Final verdict

Current `bm` state is good enough to be taken seriously as the main production-target schema.

It is not yet the smallest or cleanest possible final form, but it is already:

- structurally coherent
- migration-safe
- concurrency-aware
- identity-safe at the aggregate level
- moving in the right direction for child entities

The remaining work is cleanup and consolidation, not a redesign.
