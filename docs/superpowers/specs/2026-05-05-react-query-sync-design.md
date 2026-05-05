# React Query Sync — Design Spec

**Date:** 2026-05-05

## Problem

All cloud-fetching pages manage their own `useEffect` + `useState` loading/error boilerplate. `SharedSessionPage` additionally has a last-write-wins data loss bug: when two users save concurrently, the second publish overwrites the first because both build their snapshot from locally-cached state.

## Approach

React Query (Option B): `useQuery` for all reads, `useMutation` with optimistic updates for writes. The race condition is reduced (not fully eliminated) because cache is kept fresh via `refetchOnWindowFocus` and `invalidateQueries` after every save. Acceptable for a recreational badminton session.

## Scope

- Install `@tanstack/react-query`
- Wrap app in `QueryClientProvider` (`main.tsx`)
- Replace `useEffect`/`useState` fetch patterns in 4 pages
- Add mutations to `SharedSessionPage` and `GeneratePage`
- `cloudSync.ts` — no changes
- `SummaryModal` — no changes

## Section 1: Setup

Install `@tanstack/react-query`. Add `QueryClientProvider` in `main.tsx` with:

```ts
new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 0,
      retry: 1,
      refetchOnWindowFocus: true,
    },
  },
})
```

## Section 2: Query Keys & Queries

| Page | Query key | Fetch fn |
|---|---|---|
| `SharedSessionPage` | `['session', sessionId]` | `getSession(sessionId)` |
| `SessionListPage` | `['sessions']` | `listSessions()` |
| `PlayerHistoryPage` | `['players']` | `listPlayers()` |
| `PlayerDetailPage` | `['player', name]` | `getPlayerStats(name)` |

Each page replaces its `useEffect` + `useState` with a single `useQuery`. Loading and error UI stays the same, driven by `isLoading` / `isError`.

## Section 3: Mutations (SharedSessionPage)

### togglePlayed(key)

1. Snapshot current cache for rollback
2. Optimistically update cache: toggle `key` in `playedGames`
3. POST updated snapshot via `publishSession`
4. `onError`: rollback to snapshot, show inline error "Failed to save, please try again"
5. `onSettled`: `invalidateQueries(['session', sessionId])`

### setScore(key, a, b)

1. Snapshot current cache for rollback
2. Optimistically update cache: `{ ...prev.gameScores, [key]: { a, b } }`, add `key` to `playedGames` if absent
3. POST updated snapshot
4. `onError`: rollback, show inline error
5. `onSettled`: `invalidateQueries(['session', sessionId])`

### GeneratePage

Replace manual `publishSession` calls with a simple `useMutation` (no optimistic update — organizer is sole writer). Silent failure, no UI change.

## Section 4: Loading & Error States

**Reads:** `isLoading` / `isError` from `useQuery` replaces manual state. Existing loading/error UI unchanged.

**Mutations:**
- `isPending` disables Save button and played checkbox while save is in flight
- `onError` rollback restores previous cache — UI snaps back automatically
- Inline error text shown below Save button on failure, cleared on next successful save
