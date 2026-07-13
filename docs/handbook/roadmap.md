# Roadmap

This is the working plan for the project after the Supabase migration branch
baseline.

## Phase 1: Supabase backend migration

Status: complete

Done:

- snapshot-first landing and normalized `bm` runtime
- Supabase RPC query layer
- verified main session flow on live Supabase backend

## Phase 2: Historical bridge and parity

Status: complete

Goal:

- carry legacy session/tournament behavior safely into `bm`

Tasks:

1. backfill normalized session state into `bm`
2. preserve legacy snapshot compatibility where required
3. verify session summary parity
4. verify compatibility snapshot parity
5. align player/session stats with migrated history

Success criteria:

- migrated sessions visible in list
- player list reflects migrated history
- player stats align with migrated expectations

## Phase 3: Tournament verification

Status: mostly complete

Goal:

- fully verify tournament behavior after storage migration

Tasks:

1. save and reload groups
2. set group match scores
3. confirm standings are stable
4. confirm bracket propagation persists
5. keep smoke coverage around publish/reload paths

## Phase 4: Security hardening

Status: partial (session lock delivered)

Goal:

- define a real production security posture

Decisions needed:

- who can publish sessions?
- who can edit shared session state?
- who can write tournaments?
- do public links imply public write access or only public read access?

Delivered:

- session lock enforcement: `publish_session` rejects writes when `locked=true`
- lock button in UI with confirmation dialog
- unlock is admin-only via `bm.unlock_session` RPC (not in UI)
- delete session is admin-only (granted to anon for UI, but could be restricted)

Tasks remaining:

1. review current grants
2. decide whether to use RLS, auth, or explicit public-write rules
3. verify failure paths and abuse risk

## Phase 5: Regression coverage and merge readiness

Status: active

Goal:

- make the Supabase branch boring to merge

Tasks:

1. keep static checks clean
2. keep read/write smoke coverage green
3. add compact tests around core query and write invariants
4. keep handbook/runbook aligned with real runtime behavior

## Phase 6: Formal export boundary

Status: pending

Goal:

- make external consumption stable without touching `MDEF` internals

Tasks:

1. define `session_export v1`
2. emit export records from a `bm`-owned boundary
3. preserve manual copy/paste workflow if desired

## Phase 7: Production release baseline

Status: pending

Goal:

- move from working migration to production-grade confidence

Tasks:

1. verify real history
2. verify tournament
3. harden security
4. document environment and recovery steps
5. decide long-term integration path with `MDEF`

## Big-picture principle

Do not merge `badminton-match` and `MDEF` at the table level prematurely.

Preferred long-term shape:

- same Supabase project
- separate schemas
- stable export/import boundary
- separate domain ownership
