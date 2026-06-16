# Roadmap

This is the working plan for the project after the Supabase migration branch
baseline.

## Phase 1: Supabase backend migration

Status: complete

Done:

- separate `badminton_match` schema
- snapshot-first session and tournament persistence
- Supabase RPC query layer
- verified main session flow on live Supabase backend

## Phase 2: Historical data backfill

Status: next

Goal:

- move existing Google Sheets session history into Supabase

Tasks:

1. identify the legacy source still available
2. export historical rows
3. map rows into the current `CloudSnapshot` shape
4. import into `badminton_match.sessions`
5. verify list/stat parity

Success criteria:

- old sessions visible in list
- player list reflects history
- player stats align with legacy expectations

## Phase 3: Tournament verification

Status: pending

Goal:

- fully verify tournament behavior after storage migration

Tasks:

1. save and reload groups
2. set group match scores
3. confirm standings are stable
4. confirm bracket propagation persists
5. verify post generation still works

## Phase 4: Security hardening

Status: pending

Goal:

- define a real production security posture

Decisions needed:

- who can publish sessions?
- who can edit shared session state?
- who can write tournaments?
- do public links imply public write access or only public read access?

Tasks:

1. review current grants
2. decide whether to use RLS, auth, or explicit public-write rules
3. verify failure paths and abuse risk

## Phase 5: Formal export boundary

Status: pending

Goal:

- make external consumption stable without touching `MDEF` internals

Tasks:

1. define `session_export v1`
2. emit export records into `badminton_match.session_exports`
3. preserve manual copy/paste workflow if desired

## Phase 6: Production release baseline

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
