# Current Status

Last updated: 2026-06-18

This is the fastest handover file for continuing work on this repository.

## Branch

- current working branch: `supabase-migration`

## Core decision record

- `badminton-match` is being migrated from Google Apps Script / Google Sheets
  to Supabase
- same Supabase project as `MDEF`
- normalized operational schema: `bm`
- no `MDEF` code changes for now
- no shared core tables with `MDEF`
- normalized `bm` runtime for local app usage
- this app should rely only on `bm` as its runtime schema

## What is already done

### Database migration

Applied migration:

- [`supabase/migrations/20260616_000001_badminton_match_schema.sql`](../../supabase/migrations/20260616_000001_badminton_match_schema.sql)
- [`supabase/migrations/20260617_000003_bm_normalized_schema.sql`](../../supabase/migrations/20260617_000003_bm_normalized_schema.sql)
- [`supabase/migrations/20260617_000004_bm_compat_parity_fix.sql`](../../supabase/migrations/20260617_000004_bm_compat_parity_fix.sql)
- [`supabase/migrations/20260617_000005_bm_tournaments.sql`](../../supabase/migrations/20260617_000005_bm_tournaments.sql)
- [`supabase/migrations/20260617_000006_public_bm_rpc_wrappers.sql`](../../supabase/migrations/20260617_000006_public_bm_rpc_wrappers.sql)
- [`supabase/migrations/20260618_000007_bm_session_optimistic_concurrency.sql`](../../supabase/migrations/20260618_000007_bm_session_optimistic_concurrency.sql)
- [`supabase/migrations/20260618_000008_bm_publish_session_fail_fast.sql`](../../supabase/migrations/20260618_000008_bm_publish_session_fail_fast.sql)
- [`supabase/migrations/20260618_000009_bm_publish_session_conflict_errors.sql`](../../supabase/migrations/20260618_000009_bm_publish_session_conflict_errors.sql)
- [`supabase/migrations/20260618_000010_bm_identity_and_tournament_concurrency.sql`](../../supabase/migrations/20260618_000010_bm_identity_and_tournament_concurrency.sql)
- [`supabase/migrations/20260618_000011_bm_schema_hardening_batch_2.sql`](../../supabase/migrations/20260618_000011_bm_schema_hardening_batch_2.sql)
- [`supabase/migrations/20260618_000012_bm_tournament_snapshot_validation.sql`](../../supabase/migrations/20260618_000012_bm_tournament_snapshot_validation.sql)
- [`supabase/migrations/20260618_000013_bm_session_snapshot_validation.sql`](../../supabase/migrations/20260618_000013_bm_session_snapshot_validation.sql)
- [`supabase/migrations/20260618_000014_bm_runtime_schema_cleanup.sql`](../../supabase/migrations/20260618_000014_bm_runtime_schema_cleanup.sql)
- [`supabase/migrations/20260618_000015_bm_uuid_first_phase_a_batch_1.sql`](../../supabase/migrations/20260618_000015_bm_uuid_first_phase_a_batch_1.sql)
- [`supabase/migrations/20260618_000016_bm_uuid_first_phase_a_batch_2.sql`](../../supabase/migrations/20260618_000016_bm_uuid_first_phase_a_batch_2.sql)
- [`supabase/migrations/20260618_000017_bm_uuid_first_phase_a_batch_3.sql`](../../supabase/migrations/20260618_000017_bm_uuid_first_phase_a_batch_3.sql)
- [`supabase/migrations/20260618_000018_bm_uuid_first_phase_a_batch_4.sql`](../../supabase/migrations/20260618_000018_bm_uuid_first_phase_a_batch_4.sql)
- [`supabase/migrations/20260618_000019_bm_phase_b_domain_internal_ids.sql`](../../supabase/migrations/20260618_000019_bm_phase_b_domain_internal_ids.sql)
- [`supabase/migrations/20260618_000020_bm_phase_b_internal_id_adoption.sql`](../../supabase/migrations/20260618_000020_bm_phase_b_internal_id_adoption.sql)
- [`supabase/migrations/20260618_000021_bm_phase_b_identity_consistency.sql`](../../supabase/migrations/20260618_000021_bm_phase_b_identity_consistency.sql)
- [`supabase/migrations/20260618_000022_bm_phase_b_identity_sync_triggers.sql`](../../supabase/migrations/20260618_000022_bm_phase_b_identity_sync_triggers.sql)
- [`supabase/migrations/20260618_000023_bm_drop_legacy_schema_surface.sql`](../../supabase/migrations/20260618_000023_bm_drop_legacy_schema_surface.sql)

Created:

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

Main practical state now:

- aggregate identity is UUID-first
- session publish is internal-id-first
- app runtime depends on `bm` only
- `badminton_match` is now historical migration context, not a live runtime target

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
- normalized session parity was verified during migration work
- Google Sheets is no longer required for the tested local session flow

## What is not done yet

1. production security hardening
2. formal long-term export boundary for `MDEF`
3. remaining schema finalization work, especially bigint identity retirement inside `bm`

## Important operational truth

The persistence migration arc is effectively closed.

It is accurate to say:

- Google Sheets is no longer the active runtime direction
- `badminton_match` served as the landing bridge
- `bm` is now the only runtime schema target for this app

It is still not accurate to say:

- everything is fully hardened for production rollout

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

### Phase C: final bm schema cleanup

Order:

1. keep smoke-checking the direct `bm.*` RPC surface after changes
2. remove remaining bigint-first relational identity paths inside `bm`
3. harden production-facing access controls if deployment scope expands

Latest audit:

- [bm-write-flow-audit.md](bm-write-flow-audit.md)

## If continuing in a new session

A new session should read these first:

1. [`docs/handbook/current-status.md`](current-status.md)
2. [`docs/handbook/supabase-migration.md`](supabase-migration.md)
3. [`docs/handbook/persistence-migration-closure-2026-06-18.md`](persistence-migration-closure-2026-06-18.md)
4. [`docs/handbook/roadmap.md`](roadmap.md)

That is enough context to resume efficiently.
