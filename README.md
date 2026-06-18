# badminton-match

`badminton-match` is the operational app for running badminton sessions end to
end: planning players and courts, generating doubles schedules, publishing live
session state, tracking scores, managing tournaments, and exporting social
graphics.

It is intentionally separate from `MDEF`. This repo owns operations. `MDEF`
owns analytics and long-term rating/history concerns.

## What It Covers

### Session operations

- configure title, date, courts, court hours, and slot duration
- define player count and player pool
- apply fixed-match constraints
- generate balanced doubles schedules
- retry generation for better schedule quality

### Live session control

- publish a live session and open it from a shared link
- mark games played
- enter and revise scores
- swap players between games
- swap full game slots
- mark players absent
- rename players inside the published session

### History and stats

- browse historical sessions
- browse known players
- inspect player stats:
  wins, losses, points for/against, top partners, top opponents

### Tournament

- assign 16 pairs into 4 groups
- compute standings
- propagate knockout bracket automatically
- score tournament matches
- generate tournament visuals

### Social export

- generate Instagram-style session graphics
- generate standings and bracket visuals

## Stack

| Layer | Tools |
| --- | --- |
| App | React 19, TypeScript, Vite |
| State | Zustand, TanStack React Query |
| Routing | React Router |
| UI | Tailwind CSS v4 |
| PWA | `vite-plugin-pwa` |
| Backend | Supabase Postgres + PostgREST RPC |

## Persistence Status

This branch is the Supabase migration branch.

Current runtime direction:

- app runtime source of truth: schema `bm`
- frontend RPC target: `bm.*` via Supabase PostgREST profile headers
- historical bridge: Google Sheets -> `badminton_match` -> `bm`
- current local/runtime target: `bm` only

Important clarification:

- `badminton_match` is historical migration context, not the intended runtime
  ownership model for this app
- `public.bm_*` wrappers may still exist for compatibility, but this app should
  not rely on them

## Quick Start

### 1. Install

```bash
npm ci
```

### 2. Configure env

Copy `.env.local.example` to `.env.local` and fill in:

```bash
VITE_SUPABASE_URL=...
VITE_SUPABASE_KEY=...
```

### 3. Apply migrations

Apply the Supabase migration stack under:

- [`supabase/migrations/`](supabase/migrations/)

For the current runtime shape, the important end state is:

- schema `bm` exists and is current
- schema `bm` is exposed in Supabase API settings
- removed legacy schemas such as `badminton_match` are also removed from exposed
  schemas

If you are reconstructing the full local migration history, use the runbook:

- [`docs/handbook/bm-supabase-runbook.md`](docs/handbook/bm-supabase-runbook.md)

### 4. Run locally

```bash
npm run dev
```

## Verification

### Static checks

```bash
npm run check
```

### Supabase smoke checks

```bash
source .env.local
npm run check:smoke
```

Smoke coverage includes:

- session list
- player list
- session fetch
- tournament fetch
- session republish/version increment
- session absent mutation
- session swap mutation
- session played/score mutation
- player stats fetch
- tournament republish/version increment
- tournament score mutation

Current branch status:

- `npm run check` passes
- `npm run check:smoke` passes against the active Supabase project

## Documentation Map

### Start here

- [`docs/README.md`](docs/README.md)
- [`docs/handbook/README.md`](docs/handbook/README.md)

### Core handbook

- [`docs/handbook/current-status.md`](docs/handbook/current-status.md)
- [`docs/handbook/product-overview.md`](docs/handbook/product-overview.md)
- [`docs/handbook/architecture.md`](docs/handbook/architecture.md)
- [`docs/handbook/data-model.md`](docs/handbook/data-model.md)
- [`docs/handbook/features-and-routes.md`](docs/handbook/features-and-routes.md)
- [`docs/handbook/supabase-migration.md`](docs/handbook/supabase-migration.md)
- [`docs/handbook/bm-supabase-runbook.md`](docs/handbook/bm-supabase-runbook.md)
- [`docs/handbook/mdef-integration.md`](docs/handbook/mdef-integration.md)
- [`docs/handbook/roadmap.md`](docs/handbook/roadmap.md)

### Historical archive

- [`docs/superpowers/`](docs/superpowers)

Use `docs/superpowers/` for implementation history and rationale, not as the
current source of truth.

## Role In The Wider System

`badminton-match` should remain the operational source app:

- session planning
- live session control
- tournament administration

`MDEF` should remain the analytics destination:

- canonical players and aliases
- exported match history
- rating and longitudinal analysis

## Current Reality

What is already working on the Supabase branch:

- create and publish sessions
- open shared session links
- mark played and enter scores
- load session history
- load player history and stats
- load and update tournament state

What is still not “fully final”:

- richer automated end-to-end regression coverage
- tournament normalization beyond snapshot-first persistence
- longer-term export contract into `MDEF`
