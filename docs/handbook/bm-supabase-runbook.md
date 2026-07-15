# BM Supabase Runbook

Last updated: 2026-06-18

This runbook describes the exact SQL execution order for the new normalized
`bm` schema.

Important status:

- normalized `bm` schema has been applied and parity-verified
- frontend local mode now reads and writes directly through schema `bm`
- this app should treat `bm` as the only runtime schema surface
- `public.bm_*` may still exist for other consumers, but they are not part of
  this app's runtime contract

## Files To Run

If you are rebuilding from scratch, `supabase db reset` applies the 3 squashed
migrations in order:

1. [supabase/migrations/20260616_000001_schema.sql](../../supabase/migrations/20260616_000001_schema.sql) — all tables, indexes, constraints, triggers, grants
2. [supabase/migrations/20260616_000002_functions.sql](../../supabase/migrations/20260616_000002_functions.sql) — all 26 functions in final form
3. [supabase/migrations/20260616_000003_seeds.sql](../../supabase/migrations/20260616_000003_seeds.sql) — legacy backfill, identity seed, tournament seed, data fixes, validation

The seeds file inserts legacy snapshots into `badminton_match`, backfills into
`bm`, runs parity/smoke checks, then drops the `badminton_match` schema.

## Supabase API Config Note

If you remove a live schema such as `badminton_match`, also remove it from
Supabase `Project Settings -> API -> Exposed schemas`.

If an already-dropped schema is still exposed, PostgREST can start returning:

- `PGRST002`
- `Could not query the database for the schema cache`

Minimum recovery steps:

1. remove the dropped schema from `Exposed schemas`
2. run:
   `notify pgrst, 'reload schema';`
3. if needed, also run:
   `notify pgrst, 'reload config';`

## Recommended Execution Flow

1. Apply the full migration stack in order up to the current head in
   `supabase/migrations/`.

2. Seed the canonical identity layer:
   [20260617_bm_identity_seed.sql](/Users/user/Projects/badminton-match/supabase/seeds/20260617_bm_identity_seed.sql:1)

3. Run normalized backfill:
   [20260617_bm_backfill.sql](/Users/user/Projects/badminton-match/supabase/seeds/20260617_bm_backfill.sql:1)

4. Run parity checks:
   [20260617_bm_parity_checks.sql](/Users/user/Projects/badminton-match/supabase/seeds/20260617_bm_parity_checks.sql:1)

5. Backfill tournament snapshot into `bm.tournaments`:
   [20260617_bm_tournament_backfill.sql](/Users/user/Projects/badminton-match/supabase/seeds/20260617_bm_tournament_backfill.sql:1)

6. Run smoke checks for the RPC surface used by the local frontend:
   [20260617_bm_smoke_checks.sql](/Users/user/Projects/badminton-match/supabase/seeds/20260617_bm_smoke_checks.sql:1)

## What Success Looks Like

- session count parity matches
- per-session summary parity query returns zero rows
- compat snapshot parity query returns zero rows
- identity sanity checks return zero rows
- direct `bm.*` reads resolve successfully

## Important Note About Legacy Data

The current target state for this app is `bm`-only runtime ownership.

- use `badminton_match` only as historical migration context
- apply `000023` when you are ready to remove the live legacy schema from this
  local app database
- `public.bm_*` can remain if another project still depends on them
- after dropping a schema, clean up `Exposed schemas` in Supabase API settings too

## What You Need To Run Right Now

If you want to validate or rebuild the local-only `bm` mode, run SQL yourself in
Supabase SQL Editor or via your normal migration flow.

Minimum safe first step:

1. run the full migration stack to current head
2. run [20260617_bm_identity_seed.sql](/Users/user/Projects/badminton-match/supabase/seeds/20260617_bm_identity_seed.sql:1)
3. run backfill and parity checks only if you still need to rebuild normalized state from legacy history
