# Queries Layer Refactor

**Date:** 2026-05-10  
**Branch:** `refactor/queries-layer`  
**Status:** Approved

## Goal

Consolidate all React Query hooks and raw fetch functions — currently scattered across 6 page files and `src/utils/cloudSync.ts` — into a single `src/queries/` layer. Pages import only from `src/queries`; no page calls fetch functions directly.

## File Structure

```
src/queries/
├── endpoints.ts    # APPS_SCRIPT_URL, TOURNAMENT_ID, all raw fetch functions
├── types.ts        # CloudSnapshot, SessionMeta, PlayerSummary, PlayerStats, TournamentSnapshot
├── sessions.ts     # useListSessions, useGetSession, usePublishSession, useTogglePlayed,
│                   # useSetScore, useSwapPlayers, useSetAbsent
├── players.ts      # useListPlayers, useGetPlayerStats
├── tournament.ts   # useGetTournament, useConfirmGroups, useSetTournamentScore, useResetTournament
└── index.ts        # barrel: re-exports all hooks and types
```

`src/utils/cloudSync.ts` is **deleted** as part of this refactor.

## File Responsibilities

### `endpoints.ts`
- Exports `APPS_SCRIPT_URL` (reads from `import.meta.env.VITE_APPS_SCRIPT_URL`)
- Exports `TOURNAMENT_ID` constant
- Exports all 7 async fetch functions: `getSession`, `publishSession`, `listSessions`, `listPlayers`, `getPlayerStats`, `getTournament`, `publishTournament`
- No React Query imports — pure async functions only

### `types.ts`
- Exports all shared types currently defined in `cloudSync.ts`: `CloudSnapshot`, `SessionMeta`, `PlayerSummary`, `PlayerStats`, `TournamentSnapshot`
- `TournamentSnapshot` is re-exported from `src/utils/tournament.ts` (no change to source)

### `sessions.ts`
Imports fetch functions from `endpoints.ts`, types from `types.ts`.

Queries:
- `useListSessions()` — query key `['sessions']`
- `useGetSession(sessionId: string)` — query key `['session', sessionId]`, enabled when sessionId is truthy

Mutations (all with optimistic updates, matching current `SharedSessionPage` logic):
- `usePublishSession()` — sets query data on success
- `useTogglePlayed(sessionId)` — optimistic toggle of played game
- `useSetScore(sessionId)` — optimistic score update
- `useSwapPlayers(sessionId)` — optimistic player swap
- `useSetAbsent(sessionId)` — optimistic absent player update

### `players.ts`
Imports fetch functions from `endpoints.ts`, types from `types.ts`.

Queries:
- `useListPlayers()` — query key `['players']`
- `useGetPlayerStats(name: string)` — query key `['player', name]`, enabled when name is truthy

### `tournament.ts`
Imports fetch functions from `endpoints.ts`, types from `types.ts`.

Query:
- `useGetTournament()` — query key `['tournament', TOURNAMENT_ID]`, staleTime 60s, refetchOnWindowFocus true

Mutations (all with optimistic updates, matching current `TournamentPage` logic):
- `useConfirmGroups()` — saves group assignments
- `useSetTournamentScore()` — optimistic score update
- `useResetTournament()` — resets tournament state

### `index.ts`
Re-exports everything from `sessions.ts`, `players.ts`, `tournament.ts`, and `types.ts`. The `endpoints.ts` internals (raw fetch functions) are **not** re-exported — they are internal to the queries layer.

## Page Import Changes

| Page | Before | After |
|---|---|---|
| `SessionListPage` | `useQuery` + `listSessions` from cloudSync | `useListSessions` from `src/queries` |
| `PlayerHistoryPage` | `useQuery` + `listPlayers` from cloudSync | `useListPlayers` from `src/queries` |
| `PlayerDetailPage` | `useQuery` + `getPlayerStats` from cloudSync | `useGetPlayerStats` from `src/queries` |
| `GeneratePage` | `useMutation` + `publishSession` from cloudSync | `usePublishSession` from `src/queries` |
| `SharedSessionPage` | inline `useQuery` + `useMutation` × 4 | `useGetSession` + 4 mutation hooks from `src/queries` |
| `TournamentPage` | inline `useQuery` + `useMutation` × 3 | `useGetTournament` + 3 mutation hooks from `src/queries` |

## Constraints

- All optimistic update logic moves 1:1 from pages into domain hook files — no behaviour changes
- Query keys remain identical to current implementation
- `src/utils/cloudSync.ts` is deleted; no re-export shim left behind
- Branch: `refactor/queries-layer` (new branch off `main`)
- No new features, no changes to UI or scheduling logic

## Out of Scope

- Changes to `src/utils/tournament.ts` (pure TS utilities, not React Query)
- Changes to `src/store/` (Zustand stores)
- Any UI or feature changes
