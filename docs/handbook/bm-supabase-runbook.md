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

If you are rebuilding from scratch, apply the full migration stack under:

- [supabase/migrations/](../../supabase/migrations/)

Then apply the relevant seeds under:

- [supabase/seeds/](../../supabase/seeds/)

Do not stop at `000023`. The current working local runtime also expects the
later hardening and regression-fix migrations, including:

- `000024`
- `000025`
- `000026`
- `000027`
- `000028`

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
