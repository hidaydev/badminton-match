# BM Supabase Runbook

Last updated: 2026-06-17

This runbook describes the exact SQL execution order for the new normalized
`bm` schema.

Important status:

- normalized `bm` schema has been applied and parity-verified
- frontend local mode now reads and writes directly through schema `bm`
- `public.bm_*` wrappers may still exist for compatibility, but they are not the
  intended app surface for local `bm` mode

## Files To Run

1. [supabase/migrations/20260616_000001_badminton_match_schema.sql](/Users/user/Projects/badminton-match/supabase/migrations/20260616_000001_badminton_match_schema.sql:1)
2. [supabase/migrations/20260617_000002_badminton_match_rpc_schema_ownership.sql](/Users/user/Projects/badminton-match/supabase/migrations/20260617_000002_badminton_match_rpc_schema_ownership.sql:1)
3. [supabase/migrations/20260617_000003_bm_normalized_schema.sql](/Users/user/Projects/badminton-match/supabase/migrations/20260617_000003_bm_normalized_schema.sql:1)
4. [supabase/migrations/20260617_000004_bm_compat_parity_fix.sql](/Users/user/Projects/badminton-match/supabase/migrations/20260617_000004_bm_compat_parity_fix.sql:1)
5. [supabase/migrations/20260617_000005_bm_tournaments.sql](/Users/user/Projects/badminton-match/supabase/migrations/20260617_000005_bm_tournaments.sql:1)
6. [supabase/migrations/20260617_000006_public_bm_rpc_wrappers.sql](/Users/user/Projects/badminton-match/supabase/migrations/20260617_000006_public_bm_rpc_wrappers.sql:1)
7. [supabase/seeds/20260617_bm_identity_seed.sql](/Users/user/Projects/badminton-match/supabase/seeds/20260617_bm_identity_seed.sql:1)
8. [supabase/seeds/20260617_bm_backfill.sql](/Users/user/Projects/badminton-match/supabase/seeds/20260617_bm_backfill.sql:1)
9. [supabase/seeds/20260617_bm_tournament_backfill.sql](/Users/user/Projects/badminton-match/supabase/seeds/20260617_bm_tournament_backfill.sql:1)
10. [supabase/seeds/20260617_bm_parity_checks.sql](/Users/user/Projects/badminton-match/supabase/seeds/20260617_bm_parity_checks.sql:1)
11. [supabase/seeds/20260617_bm_smoke_checks.sql](/Users/user/Projects/badminton-match/supabase/seeds/20260617_bm_smoke_checks.sql:1)

## Recommended Execution Flow

1. Apply the full normalized stack in order:
   `000003`, `000004`, `000005`, `000006`

2. Seed the canonical identity layer:
   [20260617_bm_identity_seed.sql](/Users/user/Projects/badminton-match/supabase/seeds/20260617_bm_identity_seed.sql:1)

3. Before backfill, run unresolved-name report only:
   `select * from bm.report_legacy_unresolved_names();`

Expected result:

- zero rows

If it returns rows:

- stop
- inspect the names
- add alias or canonical decisions first

4. Run normalized backfill:
   [20260617_bm_backfill.sql](/Users/user/Projects/badminton-match/supabase/seeds/20260617_bm_backfill.sql:1)

5. Run parity checks:
   [20260617_bm_parity_checks.sql](/Users/user/Projects/badminton-match/supabase/seeds/20260617_bm_parity_checks.sql:1)

6. Backfill tournament snapshot into `bm.tournaments`:
   [20260617_bm_tournament_backfill.sql](/Users/user/Projects/badminton-match/supabase/seeds/20260617_bm_tournament_backfill.sql:1)

7. Run smoke checks for the RPC surface used by the local frontend:
   [20260617_bm_smoke_checks.sql](/Users/user/Projects/badminton-match/supabase/seeds/20260617_bm_smoke_checks.sql:1)

## What Success Looks Like

- unresolved-name report returns zero rows
- session count parity matches
- per-session summary parity query returns zero rows
- compat snapshot parity query returns zero rows
- identity sanity checks return zero rows
- direct `bm.*` reads resolve successfully

## Important Note About Legacy Data

The `bm` migration and backfill do not mutate `badminton_match`.

- `badminton_match` remains the current production-backed legacy schema
- `bm` is additive
- backfill deletes and rebuilds rows only inside `bm` for the targeted session

## What You Need To Run Right Now

If you want to validate or rebuild the local-only `bm` mode, run SQL yourself in
Supabase SQL Editor or via your normal migration flow.

Minimum safe first step:

1. run `000003`, `000004`, `000005`, `000006`
2. run [20260617_bm_identity_seed.sql](/Users/user/Projects/badminton-match/supabase/seeds/20260617_bm_identity_seed.sql:1)
3. run only `select * from bm.report_legacy_unresolved_names();`

Do not run full backfill until that unresolved-name report comes back clean.
