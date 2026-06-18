# BM V2 Schema Plan

Last updated: 2026-06-17

This document describes the recommended V2 direction for the normalized `bm`
schema after the current parity-first migration phase.

The current `bm` schema is good enough for:

- legacy snapshot backfill
- compatibility reconstruction
- local operational app usage

It should not yet be treated as the final production-grade relational design.

This plan separates:

1. what is already good and should stay
2. what should change in a cleaner V2
3. what should be explicitly deferred until compatibility pressure is lower

## Design Goals

V2 should optimize for:

- clean domain boundaries
- stable primary key strategy
- safer concurrent writes
- reduced leakage from legacy snapshot compatibility
- more explicit operational semantics

V2 should not optimize for:

- preserving every legacy field in the core domain tables
- zero-risk backfill simplicity at any cost
- premature `mdef` analytics integration

## Executive Assessment Of Current BM

Current `bm` status:

- professional enough for migration-grade work
- not yet ideal as a long-term operational schema
- structurally sound in the main domain areas
- still carrying too much compatibility metadata in core tables
- still using write patterns that are practical, but not final-grade

Important note:

- `bigserial` child ids are not inherently bad practice
- they are normal for internal relational rows
- the real issue is inconsistency of key strategy, not the existence of integer
  ids by itself

## Core V2 Principles

### 1. Internal ids and external ids should be separated

The schema should distinguish:

- internal relational identity
- external/share/public ids
- compatibility ids inherited from legacy snapshots

This is the single biggest cleanup opportunity in V2.

### 2. Compatibility fields should not dominate core domain tables

Fields that exist only to preserve legacy snapshot parity should move toward:

- import metadata tables
- compatibility projection logic
- explicitly named legacy mapping tables

They should not remain mixed into the main operational entities forever.

### 3. Full-snapshot replace writes should not be the long-term model

The current publish flow is acceptable for migration and local usage, but not as
the ideal final multi-user write model.

V2 should add:

- optimistic concurrency
- narrower mutation surfaces
- less destructive rebuild behavior

## Keep / Change / Defer By Area

## Identity Layer

### `bm.players`

Current assessment:

- keep

Why:

- canonical player registry is the right core identity model
- `uuid` primary key is appropriate here
- `canonical_name unique` is correct

Recommended V2 changes:

- keep `uuid primary key`
- add normalized-name uniqueness only if the product wants to ban canonical
  casing variants
- consider adding optional status fields later:
  - `is_active`
  - `merged_into_player_id`

Do not add yet:

- ELO
- aggregate stats columns
- analytics ownership concerns

### `bm.player_aliases`

Current assessment:

- keep

Why:

- alias resolution is one of the strongest parts of the schema
- normalized alias discipline is the right design

Recommended V2 changes:

- keep alias table as-is conceptually
- optionally add:
  - `source`
  - `notes`
  - `created_by`
  for admin/debug workflows

No urgent structural redesign is needed here.

## Session Aggregate

### `bm.sessions`

Current assessment:

- change

Current problem:

- `id text primary key` is doing too many jobs at once
- it acts as:
  - internal primary key
  - legacy session id
  - share/public id

Recommended V2 model:

- `id uuid primary key`
- `share_id text not null unique`
- optional `legacy_session_id text unique null`

Why:

- UUID is better as the internal FK target
- external ids can still stay human/share friendly
- legacy ids can be preserved without polluting the core PK strategy

Current fields to review:

- `session_tier_count`
- `include_tier_count`
- `include_absent_players`
- `source`

Recommendation:

- `source` can stay if operational provenance matters
- `session_tier_count` may stay if the app truly owns it
- `include_tier_count` and `include_absent_players` are compatibility flags and
  should move toward a compatibility metadata table in V2

Suggested V2 split:

- `bm.sessions`
  domain-owned session record
- `bm.session_compat_metadata`
  legacy reconstruction hints

## Session Courts

### `bm.session_courts`

Current assessment:

- keep

Why:

- court rows are a natural part of the domain
- `(session_id, court_index)` uniqueness is correct

Recommended V2 changes:

- if `sessions.id` moves to UUID, update FK only
- no major conceptual redesign required

`bigserial` here is acceptable.

## Session Membership

### `bm.session_players`

Current assessment:

- change

This table currently mixes:

- domain facts
- display/import ordering
- compatibility identity fields

Domain fields that make sense:

- `session_id`
- `player_id`
- `is_absent`
- maybe `display_order`
- maybe session-scoped `tier` if tier is intentionally mutable by session
- maybe session-scoped `gender` only if the app truly treats it as session data

Compatibility-heavy fields:

- `player_ref`
- `source_name`
- `sort_order`
- `absent_order`

Recommended V2 model:

- keep `session_players` as the domain membership table
- reduce it to domain-owned fields
- move legacy/import-specific fields into `bm.session_player_compat`

Example split:

### `bm.session_players`

- `id bigint generated always as identity primary key`
- `session_id uuid not null`
- `player_id uuid not null`
- `display_order integer not null`
- `is_absent boolean not null`
- `session_tier integer null`

### `bm.session_player_compat`

- `session_player_id bigint primary key`
- `legacy_player_ref text`
- `legacy_source_name text`
- `legacy_sort_order integer`
- `legacy_absent_order integer`

This separation would make the table much cleaner.

## Fixed Matches

### `bm.fix_matches`

Current assessment:

- mostly keep, but simplify

The concept is valid:

- a fixed constraint/match container tied to a session

What is transitional:

- `legacy_ref`
- `sort_order`

Recommendation:

- `sort_order` may remain if UI ordering matters
- `legacy_ref` should be moved to compat metadata if it only exists for
  snapshot reconstruction

### `bm.fix_match_slots`

Current assessment:

- keep

Why:

- 4-slot structure fits the current product model
- `on delete set null` is reasonable for partially open legacy constraints

No urgent redesign needed.

## Scheduled Games

### `bm.scheduled_games`

Current assessment:

- keep with some cleanup

What is good:

- `(session_id, slot_index, court_index)` uniqueness
- explicit per-game rows
- explicit `status`

What is transitional:

- `legacy_order`
- `source`

Recommendation:

- keep `status`
- keep structural uniqueness
- consider moving `legacy_order` to compat metadata if the UI no longer depends
  on legacy array order semantics

`bigserial` id here is fine.

### `bm.scheduled_game_players`

Current assessment:

- keep

Why:

- join table is correct
- uniqueness by `(scheduled_game_id, team, position)` is strong
- uniqueness by `(scheduled_game_id, session_player_id)` prevents duplicates

This is one of the cleaner parts of the schema already.

## Game State

### `bm.game_progress`

Current assessment:

- keep

Why:

- `is_played` separated from score entry is a valid design

What to review:

- `played_order` is mostly compatibility-oriented

Recommendation:

- keep table
- keep `played_order` only if the app still cares about explicit "played list"
  ordering
- otherwise demote it to compatibility-only metadata later

### `bm.game_scores`

Current assessment:

- keep

Why:

- score table is small, clear, and properly constrained

Potential V2 enhancement:

- if score edit history becomes important, replace single-row latest score with:
  - current score table plus audit log
  or
  - append-only score event table

For now, current design is acceptable.

## Tournament Model

### `bm.tournaments`

Current assessment:

- defer deep redesign

Current table is still snapshot-first by intention.

That is okay because:

- tournament normalization was not the priority of this phase
- it avoids mixing two migrations together

V2 options:

1. keep tournament snapshot-first longer
2. partially normalize pairs and matches
3. fully normalize tournament state

Recommended near-term choice:

- keep snapshot-first for tournament until session domain is stable

Do not normalize tournament further until session/player write semantics are
cleaner.

## Key Strategy Recommendation

This is the recommended V2 convention.

### Use UUID for top-level entities

- `players.id uuid`
- `sessions.id uuid`
- future `tournaments.id uuid` if tournament is normalized beyond snapshot mode

### Use bigint identity for internal child rows

- `session_courts.id`
- `session_players.id`
- `fix_matches.id`
- `fix_match_slots.id`
- `scheduled_games.id`
- `scheduled_game_players.id`

This hybrid model is normal and professional.

It gives:

- stable internal parent ids
- lightweight internal child ids
- simpler joins than all-text external ids

## Concurrency And Write Safety

Current model:

- frontend publishes whole snapshots
- backend rebuilds session-owned rows

This is acceptable for migration-grade work, but not ideal.

Recommended V2 additions:

- `version integer not null default 1` on mutable aggregates
- or strict `updated_at` optimistic concurrency checks
- reject stale writes

Recommended RPC evolution:

- `publish_session(..., expected_version integer)`
- `publish_tournament(..., expected_version integer)`

This would immediately improve safety without requiring a total write-model
rewrite.

## Security And API Surface

Current wrapper strategy:

- `public.bm_*` RPC wrappers call into `bm.*`

This is pragmatic when frontend RPC transport cannot rely on exposed schema
configuration.

Long-term recommendation:

- be explicit that `bm` is the source of truth
- keep wrapper RPCs thin if needed
- avoid placing business logic in `public`

Do not treat `public` wrappers as domain ownership.

## What To Keep In V1 For Now

These are acceptable to keep until compatibility pressure drops:

- `text` session ids if changing them now would destabilize cutover
- `legacy_ref`
- `legacy_order`
- `player_ref`
- `source_name`
- `absent_order`
- `include_tier_count`
- `include_absent_players`

These are not ideal, but they are understandable in a parity-first phase.

## Recommended Order Of V2 Work

1. Freeze the current parity-clean V1 schema and document it as compatibility
   oriented.
2. Introduce internal UUID session ids plus separate external/share ids.
3. Move compatibility-only fields into dedicated compat metadata tables.
4. Add optimistic concurrency to session and tournament writes.
5. Standardize enum/domain strategy for repeated constrained text fields.
6. Revisit grants/RLS only after the write model is more stable.
7. Decide whether tournament should remain snapshot-first or be normalized in a
   dedicated follow-up phase.

## Final Position

The current `bm` schema is:

- good enough for normalized local runtime and backfill
- disciplined enough to keep building on
- not yet the final "clean domain model" version

The best V2 improvement is not "replace integer ids with UUID everywhere".

The best V2 improvement is:

- clearer key roles
- less compatibility leakage in core tables
- safer write semantics
- more explicit boundaries between domain and legacy reconstruction concerns
