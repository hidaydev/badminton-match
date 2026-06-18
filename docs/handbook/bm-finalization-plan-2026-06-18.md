# BM Finalization Plan 2026-06-18

This plan turns the current `bm` schema audit into a concrete finishing backlog.

## Current status

Already done:

- `bm` is the effective runtime schema.
- Aggregate identity is UUID-first.
- Session and tournament publish flows are validated and concurrency-aware.
- Child entities now have internal UUID identity paths.
- Session publish now writes child rows internal-id-first.
- Legacy `badminton_match` runtime schema has been removed.
- Active bigint relation paths have been removed from the live schema.

This means the remaining work is finalization, not redesign.

## Goal

Reach a state where:

- `bm` is the only schema the app needs conceptually
- legacy bigint relation paths are gone from the live schema
- final schema shape is easy to explain to a future maintainer in one pass

## Phase 1: Complete active-path cleanup

Target:

- all active read and write functions in `bm` prefer internal UUID joins first
- old bigint relation paths no longer exist in the live schema

Tasks:

1. Audit the remaining `bm` functions that still join child entities through legacy numeric keys.
2. Migrate the remaining active joins to:
   - `session_internal_id`
   - `session_player_internal_id`
   - `fix_match_internal_id`
   - `scheduled_game_internal_id`
3. Remove bridge logic once the live schema no longer needs old/new dual paths.

Definition of done:

- no important runtime function depends primarily on legacy bigint relations
- active runtime functions are UUID-first by construction

Status:

- completed through `000024`, `000025`, and `000026`

## Phase 2: Final child-table identity stance

Target:

- explicitly decide which tables are true domain entities and which are only join carriers

Recommended classification:

- domain entities:
  - `sessions`
  - `tournaments`
  - `players`
  - `session_players`
  - `fix_matches`
  - `scheduled_games`
- likely join/internal carriers:
  - `session_courts`
  - `fix_match_slots`
  - `scheduled_game_players`
  - `game_progress`
  - `game_scores`

Decision questions:

1. Should `fix_match_slots` get its own `internal_id uuid`?
2. Should `scheduled_game_players` get its own `internal_id uuid`?
3. Should `game_progress` and `game_scores` stay as one-to-one extension tables keyed by game, or move to dedicated UUID identity?

Default recommendation:

- keep `game_progress` and `game_scores` as one-to-one extension tables
- join tables may still use UUID PKs even if they remain structural carriers

Status:

- completed in the live schema
- `session_courts`, `fix_match_slots`, and `scheduled_game_players` now also carry UUID primary identity

## Phase 3: Reduce compatibility surface

Target:

- keep compatibility only where it still provides real value

Tasks:

1. Review `public` wrappers and mark each one as:
   - still needed
   - safe to retire later
2. Review `*_compat` functions and document why each still exists.
3. Keep `badminton_match` references historical only; do not let new runtime paths depend on them.

Definition of done:

- every compatibility layer has an explicit reason to exist

Status:

- `badminton_match` runtime dependency removed
- this app runtime no longer relies on `public`
- remaining compatibility surface is mostly historical docs and projection helpers

## Phase 4: Canonical schema documentation

Target:

- make final `bm` architecture readable without replaying the entire migration history

Tasks:

1. Produce a canonical schema map with one section per table:
   - purpose
   - primary identity
   - important uniqueness rules
   - transitional columns
2. Produce a function map:
   - publish
   - read/list
   - stats/reporting
   - compatibility
3. Classify migrations by purpose:
   - baseline
   - hardening
   - compatibility
   - UUID transition

Definition of done:

- a new maintainer can understand the `bm` model from docs first, migrations second

## Phase 5: Optional consolidation

This phase is optional and only worth doing if the project keeps evolving.

Options:

1. Create a fresh “end-state schema snapshot” migration for reference only.
2. Reduce duplicated constraints if some old identity paths become truly unused.
3. Introduce lightweight schema tests for key invariants.

## Recommended order

1. Document the now-complete active-path cleanup.
2. Document final child-table identity stance.
3. Document the remaining compatibility surface.
4. Publish canonical schema docs.
5. Only then consider consolidation.

## Phase 1 progress note

After `20260618_000026_bm_phase_c_uuid_relations_batch_3.sql`:

- the main session publish flow is internal-id-first
- active bigint relation paths are gone
- UUID identity now anchors both parent and child tables in the live schema

## Practical stop point

The project is already past the risky part and past the relational identity migration.

If work stops after documentation cleanup plus light compatibility review, `bm` is still in a very good state.
The remaining phases improve clarity and long-term maintenance, not basic correctness.
