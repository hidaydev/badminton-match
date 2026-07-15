# Migration Tracking

This document tracks which migrations in `supabase/migrations/` contain final state vs. superseded function rewrites. Useful for understanding the migration chain without replaying all 52 files.

## Final Function Versions

| Function | Final Migration | Notes |
|----------|----------------|-------|
| `bm.publish_session` | 000050 | Non-draft rejection + validation reordered after lock |
| `bm.get_session` | 000015 | Delegates to `get_session_snapshot_compat` + appends version |
| `bm.get_session_snapshot_compat` | 000020 | Pure internal_id references |
| `bm.list_sessions` | 000048 | Returns `locked boolean` column |
| `bm.list_players` | 000028 | Fixed ORDER BY after id column removal |
| `bm.get_player_stats` | 000033 | Delegates to `get_player_stats_compat` |
| `bm.get_player_stats_compat` | 000033 | Pure internal_id references |
| `bm.register_player` | 000052 | TOCTOU-safe: re-queries alias after INSERT |
| `bm.publish_tournament` | 000042 | Advisory lock + capture `found` before CTEs |
| `bm.get_tournament` | 000015 | Uses `resolve_tournament_lookup` |
| `bm.unlock_session` | 000050 | Advisory lock + version bump + draft check |
| `bm.delete_session` | 000051 | Lock check (rejects non-draft) + cascade delete |
| `bm.delete_player` | 000040 | Uses UUID instead of name |
| `bm.validate_session_snapshot` | 000031 | Full validation (record alias fix) |
| `bm.validate_tournament_snapshot` | 000034 | 32 matches; phase breakdown |
| `bm.resolve_session_lookup` | 000015 | Lookup by id/share_id/internal_id |
| `bm.resolve_tournament_lookup` | 000015 | Lookup by id/share_id/internal_id |
| `bm.normalize_player_name` | 000003 | Never rewritten |
| `bm.ensure_player` | 000003 | Never rewritten |

## Superseded Migrations

Migrations that ONLY contain function rewrites later overwritten. Their changes don't exist in the final state.

| Migration | Superseded By | Function(s) Rewritten |
|-----------|--------------|----------------------|
| 000001 | 000003 + 000023 | Legacy schema + public RPCs |
| 000002 | 000003 + 000023 | `badminton_match.*` RPCs |
| 000004 | 000007 | publish_session, get_session_snapshot_compat |
| 000007 | 000008 | publish_session, get_session |
| 000008 | 000009 | publish_session |
| 000009 | 000015 | publish_session |
| 000014 | 000015 | publish_session (search_path) |
| 000015 | 000016 | publish_session |
| 000016 | 000020 | publish_session |
| 000017 | 000020 | get_session_snapshot_compat, list_sessions, list_players, get_player_stats_compat |
| 000020 | 000022 | publish_session, get_session_snapshot_compat, get_player_stats_compat |
| 000022 | 000036 | publish_session |
| 000025 | 000033 | get_player_stats_compat |
| 000030 | 000042 | publish_tournament |
| 000036 | 000037 | publish_session, publish_tournament (errcodes) |
| 000037 | 000041 | publish_session, publish_tournament |
| 000039 | 000052 | register_player |
| 000041 | 000042 | publish_session, publish_tournament |
| 000042 | 000043 | publish_session only (tournament still final) |
| 000043 | 000045 | publish_session |
| 000045 | 000046 | publish_session, unlock_session |
| 000046 | 000050 | publish_session, unlock_session |

## Errcode Flip-Flop

Three migrations that cancel each other out:
- 000009: Removed errcodes from publish_session
- 000036: Restored errcodes to publish_session + publish_tournament
- 000037: Removed errcodes again (PostgREST hangs on custom PL/pgSQL error codes)

Net effect: errcodes are removed. Client detects version mismatch via message substring matching.

## Grant Flip-Flop

- 000027: Revoked internal function grants from anon/authenticated
- 000028: Re-granted them

Net effect: grants are present.

## Consolidation (Fresh Database Only)

For a fresh database (`supabase db reset`), migrations can be squashed into 5 groups:

1. **Schema** (000001–000026): All tables in final form + drop legacy schema
2. **Hardening** (000027–000034): Indexes, constraints, validation functions
3. **RPCs** (000035–000052): All functions in final form + grants
4. **Seeds**: Identity data, backfill, parity checks
5. **Data fixes** (000049): Status value corrections

**WARNING:** Do NOT squash migrations on an existing production database. The `supabase_migrations.schema_migrations` table tracks applied migrations. Removing files that were already applied will cause `supabase db push` to fail.
