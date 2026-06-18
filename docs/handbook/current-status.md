# Current Status

Last updated: 2026-06-17

This is the fastest handover file for continuing work on this repository.

## Branch

- current working branch: `supabase-migration`

## Core decision record

- `badminton-match` is being migrated from Google Apps Script / Google Sheets
  to Supabase
- same Supabase project as `MDEF`
- normalized operational schema: `bm`
- legacy compatibility schema: `badminton_match`
- no `MDEF` code changes for now
- no shared core tables with `MDEF`
- normalized `bm` runtime for local app usage
- legacy snapshot compatibility retained for backfill and parity

## What is already done

### Database migration

Applied migration:

- [`supabase/migrations/20260616_000001_badminton_match_schema.sql`](../../supabase/migrations/20260616_000001_badminton_match_schema.sql)
- [`supabase/migrations/20260617_000003_bm_normalized_schema.sql`](../../supabase/migrations/20260617_000003_bm_normalized_schema.sql)
- [`supabase/migrations/20260617_000004_bm_compat_parity_fix.sql`](../../supabase/migrations/20260617_000004_bm_compat_parity_fix.sql)
- [`supabase/migrations/20260617_000005_bm_tournaments.sql`](../../supabase/migrations/20260617_000005_bm_tournaments.sql)
- [`supabase/migrations/20260617_000006_public_bm_rpc_wrappers.sql`](../../supabase/migrations/20260617_000006_public_bm_rpc_wrappers.sql)

Created:

- `badminton_match.sessions`
- `badminton_match.tournaments`
- `badminton_match.session_exports`
- `bm.sessions`
- `bm.players`
- `bm.player_aliases`
- `bm.tournaments`

RPC functions created for local app usage:

- `bm_publish_session`
- `bm_get_session`
- `bm_list_sessions`
- `bm_list_players`
- `bm_get_player_stats`
- `bm_publish_tournament`
- `bm_get_tournament`

The local app now targets the underlying `bm.*` functions directly through the
`bm` PostgREST profile.

### Frontend migration

The query layer has been switched from Apps Script to Supabase RPCs.

Main file:

- [`src/queries/endpoints.ts`](../../src/queries/endpoints.ts)

### Documentation baseline

Current-state docs exist under:

- [`docs/handbook/`](.)

Historical implementation archive remains under:

- [`docs/superpowers/`](../superpowers)

## What has been verified

Verified against the real Supabase project:

1. create small test session
2. publish session
3. open shared session link
4. mark one game played
5. enter score
6. read back:
   - sessions list
   - player list
   - player stats
7. backfill normalized `bm` session data from legacy snapshots
8. verify summary parity and full snapshot parity

Verified result:

- local app session flow works against `bm`
- local app tournament flow is wired to `bm`
- player stats query works on Supabase
- normalized session backfill is parity-clean against legacy snapshots
- Google Sheets is no longer required for the tested local session flow

## What is not done yet

1. historical data backfill from legacy Google Sheets storage
2. production security hardening
3. formal long-term export boundary for `MDEF`

## Important operational truth

The migration is functionally viable, but not yet fully production-grade.

It is accurate to say:

- core session storage has been successfully migrated to Supabase

It is not yet accurate to say:

- all functionality is fully verified and hardened for production

## Historical backfill reality

The repository does **not** appear to contain reusable Google Sheets export
credentials.

What exists:

- old Apps Script source:
  [`apps-script/Code.gs`](../../apps-script/Code.gs)

What does not appear to exist:

- Google Sheets API credentials
- service account credentials
- OAuth export setup
- reusable sheet export toolchain

So historical backfill will require one of:

1. manual spreadsheet export
2. direct sheet access from the owner
3. a still-working legacy Apps Script endpoint that exposes the old rows

## Latest important commits

These are the main migration/doc checkpoints so far:

- `da02b91` — `Add Supabase schema and RPC query layer`
- `1b5c835` — `Add project baseline and migration docs`
- `f38e038` — `Organize docs into handbook and archive`
- `32d0593` — `Remove duplicated SQL from docs`

## Recommended next task

Next session should start with:

### Phase 3: stabilization

Order:

1. keep smoke-checking the direct `bm.*` RPC surface after changes
2. audit UI write flows against normalized storage
3. decide whether any legacy-only SQL can be retired from local workflow

Latest audit:

- [bm-write-flow-audit.md](bm-write-flow-audit.md)

## If continuing in a new session

A new session should read these first:

1. [`docs/handbook/current-status.md`](current-status.md)
2. [`docs/handbook/supabase-migration.md`](supabase-migration.md)
3. [`docs/handbook/roadmap.md`](roadmap.md)

That is enough context to resume efficiently.
