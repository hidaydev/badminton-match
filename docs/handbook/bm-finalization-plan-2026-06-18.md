# BM Finalization Plan 2026-06-18

This plan turns the current `bm` schema audit into a concrete finishing backlog.

## Current status

Already done:

- `bm` is the effective runtime schema.
- Aggregate identity is UUID-first.
- Session and tournament publish flows are validated and concurrency-aware.
- Child entities now have internal UUID identity paths.
- Dual-path consistency has been hardened with composite constraints.
- Session publish now writes child rows internal-id-first, with sync triggers maintaining compatibility columns.

This means the remaining work is finalization, not redesign.

## Goal

Reach a state where:

- `bm` is the only schema the app needs conceptually
- legacy bigint/text identity paths are compatibility-only, not primary logic paths
- final schema shape is easy to explain to a future maintainer in one pass

## Phase 1: Complete active-path cleanup

Target:

- all active read and write functions in `bm` prefer internal UUID joins first
- old bigint/text relation paths remain only as compatibility support

Tasks:

1. Audit the remaining `bm` functions that still join child entities through legacy numeric keys.
2. Migrate the remaining active joins to:
   - `session_internal_id`
   - `session_player_internal_id`
   - `fix_match_internal_id`
   - `scheduled_game_internal_id`
3. Keep sync triggers and composite identity constraints wherever both old and new columns still coexist.

Definition of done:

- no important runtime function depends primarily on legacy bigint relations
- legacy relation columns can be treated as compatibility carriers, not primary write inputs

## Phase 2: Decide final child-table identity stance

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
- only add UUID PKs to join tables if real product/API needs appear

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

1. Finish active-path cleanup.
2. Decide final child-table identity stance.
3. Document compatibility surface.
4. Publish canonical schema docs.
5. Only then consider consolidation.

## Phase 1 progress note

After `20260618_000022_bm_phase_b_identity_sync_triggers.sql`:

- the main session publish flow is already internal-id-first
- hybrid identity tables are protected by sync triggers
- Phase 1 is now mostly about finishing residual read-path cleanup and confirming there are no important holdouts

## Practical stop point

The project is already past the risky part.

If work stops after Phase 1 plus Phase 4, `bm` is still in a very good state.
The remaining phases improve clarity and long-term maintenance, not basic correctness.
