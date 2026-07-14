# Current Status

Last updated: 2026-07-13 (lock fix)

This is the fastest handover file for continuing work on this repository.

## Branch

- current working branch: `supabase-migration`

## Core decision record

- `badminton-match` has completed its runtime move from Google Apps Script /
  Google Sheets to Supabase on this branch
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
- [`supabase/migrations/20260618_000024_bm_phase_c_uuid_relations_batch_1.sql`](../../supabase/migrations/20260618_000024_bm_phase_c_uuid_relations_batch_1.sql)
- [`supabase/migrations/20260618_000025_bm_phase_c_uuid_relations_batch_2.sql`](../../supabase/migrations/20260618_000025_bm_phase_c_uuid_relations_batch_2.sql)
- [`supabase/migrations/20260618_000026_bm_phase_c_uuid_relations_batch_3.sql`](../../supabase/migrations/20260618_000026_bm_phase_c_uuid_relations_batch_3.sql)
- [`supabase/migrations/20260618_000027_bm_runtime_hardening.sql`](../../supabase/migrations/20260618_000027_bm_runtime_hardening.sql)
- [`supabase/migrations/20260618_000028_bm_runtime_regression_fix.sql`](../../supabase/migrations/20260618_000028_bm_runtime_regression_fix.sql)
- [`supabase/migrations/20260618_000029_bm_perf_indexes.sql`](../../supabase/migrations/20260618_000029_bm_perf_indexes.sql)
- [`supabase/migrations/20260618_000030_bm_tournament_concurrency_hardening.sql`](../../supabase/migrations/20260618_000030_bm_tournament_concurrency_hardening.sql)
- [`supabase/migrations/20260618_000031_bm_validate_session_snapshot_record_alias_fix.sql`](../../supabase/migrations/20260618_000031_bm_validate_session_snapshot_record_alias_fix.sql)
- [`supabase/migrations/20260618_000032_bm_drop_legacy_identity_sync_triggers.sql`](../../supabase/migrations/20260618_000032_bm_drop_legacy_identity_sync_triggers.sql)
- [`supabase/migrations/20260618_000033_bm_reapply_player_stats_uuid_only.sql`](../../supabase/migrations/20260618_000033_bm_reapply_player_stats_uuid_only.sql)
- [`supabase/migrations/20260618_000034_bm_tournament_snapshot_validation_fix.sql`](../../supabase/migrations/20260618_000034_bm_tournament_snapshot_validation_fix.sql)
- [`supabase/migrations/20260618_000035_bm_register_player_rpc.sql`](../../supabase/migrations/20260618_000035_bm_register_player_rpc.sql)
- [`supabase/migrations/20260618_000036_bm_restore_errcodes.sql`](../../supabase/migrations/20260618_000036_bm_restore_errcodes.sql)
- [`supabase/migrations/20260618_000037_bm_drop_errcodes_for_postgrest_compat.sql`](../../supabase/migrations/20260618_000037_bm_drop_errcodes_for_postgrest_compat.sql)
- [`supabase/migrations/20260618_000038_bm_cleanup_rpcs.sql`](../../supabase/migrations/20260618_000038_bm_cleanup_rpcs.sql)
- [`supabase/migrations/20260618_000039_bm_fix_register_player_case.sql`](../../supabase/migrations/20260618_000039_bm_fix_register_player_case.sql)
- [`supabase/migrations/20260618_000040_bm_fix_delete_player_use_id.sql`](../../supabase/migrations/20260618_000040_bm_fix_delete_player_use_id.sql)
- [`supabase/migrations/20260618_000041_bm_fix_publish_new_session_internal_id.sql`](../../supabase/migrations/20260618_000041_bm_fix_publish_new_session_internal_id.sql)
- [`supabase/migrations/20260621_000042_bm_fix_publish_v_id_null_for_new_sessions.sql`](../../supabase/migrations/20260621_000042_bm_fix_publish_v_id_null_for_new_sessions.sql)
- [`supabase/migrations/20260621_000043_bm_publish_session_advisory_lock.sql`](../../supabase/migrations/20260621_000043_bm_publish_session_advisory_lock.sql)
- [`supabase/migrations/20260713_000044_bm_delete_session_anon_access.sql`](../../supabase/migrations/20260713_000044_bm_delete_session_anon_access.sql)
- [`supabase/migrations/20260713_000045_bm_session_lock.sql`](../../supabase/migrations/20260713_000045_bm_session_lock.sql)
- [`supabase/migrations/20260713_000046_bm_fix_session_lock.sql`](../../supabase/migrations/20260713_000046_bm_fix_session_lock.sql)

Created:

- `bm.sessions`
- `bm.players`
- `bm.player_aliases`
- `bm.tournaments`

RPC functions created for local app usage:

- `bm.publish_session`
- `bm.get_session`
- `bm.list_sessions`
- `bm.list_players`
- `bm.get_player_stats`
- `bm.register_player`
- `bm.publish_tournament`
- `bm.get_tournament`
- `bm.delete_session` (admin-only)
- `bm.delete_player` (admin-only)
- `bm.unlock_session` (admin-only, not wired to UI)

The local app now targets the underlying `bm.*` functions directly through the
`bm` PostgREST profile.

Main practical state now:

- aggregate identity is UUID-first
- session publish is internal-id-first
- app runtime depends on `bm` only
- `badminton_match` is now historical migration context, not a live runtime target
- active relational graph in `bm` is UUID-first
- exposed-schema/runtime drift was fixed during verification
- session lock enforcement is active (`publish_session` rejects writes when `locked=true`)
- delete session and unlock session are admin-only RPCs (not wired to UI)

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
9. verify local app reads after removing legacy exposed-schema assumptions
10. run compact static + regression suite locally
11. run live Supabase smoke suite end to end:
   - session list
   - player list
   - session publish/version flow
   - player stats RPC
   - tournament publish/version flow

Verified result:

- local app session flow works against `bm`
- local app tournament flow is wired to `bm`
- player stats query works on Supabase
- `npm run check` passes on this branch
- `npm run check:smoke` passes against the configured Supabase project
- normalized session parity was verified during migration work
- Google Sheets is no longer required for the tested local session flow
- legacy runtime dependency has been removed from the local app path

## What is not done yet

1. production security hardening (partial: session lock enforcement delivered)
2. formal long-term export boundary for `MDEF`
3. broader end-to-end/UI regression coverage beyond the compact RPC/writeflow suite

## Important operational truth

The persistence migration arc is effectively closed.

It is accurate to say:

- Google Sheets is no longer the active runtime direction
- `badminton_match` served as the landing bridge
- `bm` is now the only runtime schema target for this app

It is still not accurate to say:

- everything is fully hardened for production rollout

Operational note:

- if a schema is dropped from the database, it must also be removed from
  Supabase `Exposed schemas`
- otherwise PostgREST can return `PGRST002` schema cache errors even when app
  code is correct

## Historical backfill reality

The branch has already completed the practical bridge from legacy snapshot
history into `bm`.

What still matters:

- historical Google Sheets / Apps Script details remain relevant as origin
  context
- they are no longer required for the active local runtime path
- future historical imports, if any, should target `bm`-compatible shapes rather
  than revive `badminton_match` as an application dependency

## Latest important commits

These are the main migration/doc checkpoints so far:

- `da02b91` — `Add Supabase schema and RPC query layer`
- `1b5c835` — `Add project baseline and migration docs`
- `f38e038` — `Organize docs into handbook and archive`
- `32d0593` — `Remove duplicated SQL from docs`
- `89dd9c2` — `feat: add delete session button + fix IG leaderboard absent bug`
- `a0b6a2b` — `feat: editable court names after lock + edit schedule before share`
- `3aff325` — `feat: manual match + time assignment (pinned fix matches)`
- `032711b` — `feat: show player stats in shared session schedule tab`
- `19ffbf2` — `feat: lock session feature`
- `823a940` — `fix: session lock enforcement uses status column`
- `884a406` — `fix: show Locked badge when session is locked`
- (pending) — `fix: lock flag must be set in both CloudSnapshot and session object`

## Recommended next task

Next session should start with:

### Phase D: hardening and merge readiness

Order:

1. keep smoke-checking the direct `bm.*` RPC surface after changes
2. expand regression coverage from compact RPC checks into higher-level UI or browser flows
3. harden production-facing access controls if deployment scope expands
4. document unlock procedure for locked sessions (admin-only via Supabase SQL Editor)

Latest audit:

- [bm-write-flow-audit.md](bm-write-flow-audit.md)

## Session lock feature

### How it works

1. Host clicks "🔒 Lock session" in Actions dropdown
2. Confirmation dialog appears
3. On confirm, `publish_session` is called with `locked: true` in the snapshot
4. The session status is set to `'locked'` in the database
5. All interactive elements are disabled (checkboxes, scores, actions)
6. Any mutation attempt is rejected by the server

### Important: locked must be set in both places

The `locked` flag must be set in **both** `CloudSnapshot.locked` AND `session.locked`:

```typescript
// Correct:
await publishSession(sessionId, { 
  ...current, 
  locked: true,
  session: { ...current.session, locked: true }
})

// Wrong (only sets CloudSnapshot.locked, not session.locked):
await publishSession(sessionId, { ...current, locked: true })
```

The server reads `p_snapshot->'session'->>'locked'` to determine the lock state. If only `CloudSnapshot.locked` is set, the server ignores it.

### How to unlock (admin-only)

Unlock is intentionally NOT available in the UI. To unlock a session:

1. Open Supabase Dashboard → SQL Editor
2. Run:
   ```sql
   SELECT bm.unlock_session('<session-id>');
   ```
   Replace `<session-id>` with the actual session ID.

This sets the session status back to `'draft'` and allows edits again.

## If continuing in a new session

A new session should read these first:

1. [`docs/handbook/current-status.md`](current-status.md)
2. [`docs/handbook/supabase-migration.md`](supabase-migration.md)
3. [`docs/handbook/persistence-migration-closure-2026-06-18.md`](persistence-migration-closure-2026-06-18.md)
4. [`docs/handbook/roadmap.md`](roadmap.md)

That is enough context to resume efficiently.
