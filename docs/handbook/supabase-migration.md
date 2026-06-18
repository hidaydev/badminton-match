# Supabase Migration

Last updated: 2026-06-18

This document tracks the migration of `badminton-match` from Google Apps
Script / Google Sheets to Supabase, and records the path from the initial
landing schema to the current `bm` runtime target.

## Goal

Move `badminton-match` to Supabase without changing the product model:

- same session flow
- same publish/share flow
- same shared-session operations
- same player-history behavior
- no `MDEF` changes yet

The migration started snapshot-first and later evolved into a normalized
`bm` runtime architecture.

## Architecture choice

### Supabase project

- same Supabase project as `MDEF`

### Schema boundary

Migration path:

1. landing schema: `badminton_match`
2. normalized runtime schema: `bm`

This allowed a low-risk landing first, then a cleaner long-term runtime model.

### Storage strategy

Stage 1:

- snapshot-centric landing in `badminton_match`

Stage 2:

- normalized runtime ownership in `bm`
- compatibility snapshot surfaces retained where useful
- direct app dependency moved to `bm` only

## Implemented

### Database layer

The migration started with a `badminton_match` landing schema, then moved the
app onto the normalized `bm` runtime.

Important live result:

- session runtime ownership: `bm`
- tournament runtime ownership: `bm`
- app-facing RPC surface: `bm.*`
- legacy landing schema is historical context, not active app ownership

### Frontend query layer

The app query layer was switched from Apps Script fetches to Supabase RPC
calls while preserving the existing frontend data shapes.

Main file:

- [src/queries/endpoints.ts](/Users/user/Projects/badminton-match/src/queries/endpoints.ts:1)

### Environment contract

Switched from:

- `VITE_APPS_SCRIPT_URL`

to:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_KEY`

Example file:

- [.env.local.example](/Users/user/Projects/badminton-match/.env.local.example:1)

## Verified

Verified against the live Supabase project on branch `supabase-migration`:

1. create a small test session
2. publish session
3. open shared session link
4. mark one game played
5. enter score
6. query Supabase directly for:
   - sessions list
   - player list
   - player stats

Observed:

- session persisted correctly
- shared-session writes persisted correctly
- list/stat read surfaces returned correct data
- parity checks between legacy snapshots and `bm` compatibility snapshots passed

## Not yet verified

These are still open:

1. production security hardening
2. compact automated regression coverage for read/write flows
3. formal export surface for future `MDEF` integration

## Current status

### What is true

- the main session feature set is now running on Supabase
- the app no longer depends on Google Sheets for the tested local session flows
- `bm` is the primary runtime schema
- `badminton_match` is now mainly migration history and compatibility context
- the migration is viable and structurally coherent
- the app no longer needs `public.bm_*` wrappers as its own contract

### What is not yet true

- this is not fully production-hardened yet
- security posture has not been tightened enough for a production claim

## Big plan

### Phase 1: Supabase landing

Status: done

- create `badminton_match` landing schema
- replace Apps Script query layer
- validate main session flows

### Phase 2: normalized `bm` runtime migration

Status: done

Goal:

- move the active runtime architecture onto `bm`

Delivered:

- normalized schema
- parity backfill
- optimistic concurrency
- validation
- UUID-first identity hardening
- internal-id-first session write path

### Phase 3: historical bridge and parity

Status: done

Goal:

- carry legacy behavior safely into `bm` without reviving legacy runtime

Delivered:

- normalized backfill into `bm`
- summary parity verification
- compatibility snapshot parity verification
- identity cleanup sufficient for app runtime migration

### Phase 4: tournament verification

Status: mostly done

Goal:

- confirm tournament persistence and reload behavior on Supabase

Work:

1. create/update group assignments
2. save tournament
3. reload tournament
4. set bracket scores
5. verify propagated bracket state persists correctly

### Phase 5: security hardening

Status: pending

Goal:

- make the backend safe enough for real production use

Work:

1. decide who is allowed to write:
   - sessions
   - tournament
   - shared-session score updates
2. review grants
3. add RLS or explicit public-write policy
4. verify failure behavior

### Phase 6: export surface for `MDEF`

Status: deferred

Goal:

- keep `MDEF` untouched for now, but prepare a cleaner handoff

Short-term:

- manual JSON copy/paste is acceptable

Later:

- stable export payload from a `bm`-owned export boundary
- optional URL-based export again if needed

### Phase 7: documentation baseline and closure

Status: active

Goal:

- replace the placeholder repo docs with a usable system baseline

Delivered:

- root `README`
- architecture, data model, route, integration, and roadmap docs

Remaining:

- keep docs aligned with runtime truth
- keep smoke/runbook notes aligned with operational reality
- reduce compatibility surface only when safe

## Google Sheets export reality

### Can this repo export the old Google Sheets data automatically right now?

Not from the repository alone.

What the repo still contains:

- old Apps Script source:
  [apps-script/Code.gs](/Users/user/Projects/badminton-match/apps-script/Code.gs:1)

What the repo does **not** contain:

- Google service account credentials
- Google Sheets API credentials
- OAuth client setup for Sheets export
- an Apps Script deployment secret or authenticated export mechanism
- the actual spreadsheet identifier in a reusable export toolchain

So, unless data is still reachable through a live Apps Script endpoint you
control, historical export must come from one of these:

1. manual spreadsheet export
2. a temporary one-off script using your Google access
3. a direct Apps Script/Sheet dump performed outside this repo

### Practical implication now

Old Google Sheets access is no longer a blocker for the local app runtime.

It only matters if you want to recover or inspect older external history that
has not already been carried into the current `bm`-based working set.

## Recommended next step

Tomorrow:

1. keep `bm` smoke checks passing after schema/app changes
2. add compact regression coverage around core write flows
3. harden production-facing access control
4. only then formalize the `MDEF` export boundary
