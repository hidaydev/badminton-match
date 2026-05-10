# Tournament Cloud Sync — Design Spec

**Date:** 2026-05-10  
**Status:** Approved

## Overview

Integrate the tournament feature with Google Sheets via the existing Google Apps Script backend. Tournament state is saved as a JSON blob per record in a new `Tournament` sheet tab, following the same pattern as session cloud sync. Every score entry and group lock auto-saves to the cloud and triggers a React Query refetch.

---

## 1. Google Sheet Structure

A new sheet tab named `Tournament` is added to the existing spreadsheet.

| Column A | Column B | Column C | Column D |
|----------|----------|----------|----------|
| id | name | date | data (JSON blob) |

Each row is one tournament record. Example:

```
tournament-2026-05-23-majadu | MAJADU Internal Tournament 2026 | 2026-05-23 | {...}
```

The JSON blob (`TournamentSnapshot`) contains the full tournament state:

```ts
interface TournamentSnapshot {
  name: string
  date: string
  pairs: TournamentPair[]
  groups: Record<GroupId, string[]>
  groupsLocked: boolean
  matches: TournamentMatch[]
}
```

---

## 2. Apps Script Changes

Two new `action` branches added to the existing GET handler and one new branch in the POST handler. All changes are **additive** — no existing handlers are modified.

### GET `?action=getTournament&id=<id>`
- Find the row in the `Tournament` sheet where column A === `id`
- Return `{ ok: true, data: JSON.parse(columnD) }`
- If not found: `{ ok: false, error: 'not found' }`

### POST with `{ type: 'tournament', id, data: TournamentSnapshot }`
- If a row with matching `id` exists: overwrite column D with `JSON.stringify(data)`
- Otherwise: append new row `[id, data.name, data.date, JSON.stringify(data)]`
- Return `{ ok: true }`

> `listTournaments` action is omitted from this scope — only one tournament exists and there is no browse UI planned.

---

## 3. Frontend Changes

### 3a. `src/utils/cloudSync.ts`

Add three exports alongside existing functions:

```ts
export const TOURNAMENT_ID = 'tournament-2026-05-23-majadu'

export type TournamentSnapshot = {
  name: string
  date: string
  pairs: TournamentPair[]
  groups: Record<GroupId, string[]>
  groupsLocked: boolean
  matches: TournamentMatch[]
}

export async function getTournament(id: string): Promise<TournamentSnapshot | null>
// GET ?action=getTournament&id=<id>

export async function publishTournament(id: string, data: TournamentSnapshot): Promise<void>
// POST { type: 'tournament', id, data }
```

### 3b. `src/store/tournament.ts`

No changes. The Zustand store remains the local-first state manager — React Query sync is layered on top.

### 3c. `src/pages/TournamentPage.tsx`

Becomes the cloud sync orchestrator. Changes:

**Load from cloud on mount:**
```ts
useQuery({
  queryKey: ['tournament', TOURNAMENT_ID],
  queryFn: () => getTournament(TOURNAMENT_ID),
  // on success: hydrate the Zustand store via useTournamentStore.setState(data)
})
```

**Three `useMutation` wrappers** — each follows the SharedSessionPage pattern:
1. Optimistic: call store action (handles local state + `propagateBracket`)
2. `mutationFn`: build snapshot from `useTournamentStore.getState()`, call `publishTournament`
3. `onError`: rollback not needed (store already has the state)
4. `onSettled`: `queryClient.invalidateQueries(['tournament', TOURNAMENT_ID])`

Mutations:
- `handleSetMatchScore(matchId, scoreA, scoreB)` — wraps `setMatchScore`
- `handleLockGroups()` — wraps `lockGroups`
- `handleResetGroups()` — wraps `resetGroups`

**Saving indicator:** `isSaving` derived from any mutation's `isPending` state, shown as a small spinner/label in the header.

**saveError:** error string shown as a toast if any mutation fails.

### 3d. Component prop changes (minimal)

Components still read all state from Zustand directly (`pairs`, `groups`, `matches`). Only the mutation call sites are lifted:

| Component | Old | New |
|-----------|-----|-----|
| `GroupMatches` | calls `setMatchScore` from store | receives `onSetMatchScore` prop |
| `GroupMatches` | calls `resetGroups` from store | receives `onResetGroups` prop |
| `BracketTab` | calls `setMatchScore` from store | receives `onSetMatchScore` prop |
| `GroupAssignment` | calls `lockGroups` from store | receives `onLockGroups` prop |

`ScoreModal` is unchanged — it calls `onConfirm(scoreA, scoreB)` which the parent already passes through.

---

## 4. Data Flow

```
User enters score in ScoreModal
  → onConfirm(a, b) called in GroupMatches / BracketTab
  → handleSetMatchScore(matchId, a, b) in TournamentPage
    → store.setMatchScore(matchId, a, b)  [local state + propagateBracket]
    → publishTournament(TOURNAMENT_ID, getState())  [cloud save]
    → queryClient.invalidateQueries(['tournament', TOURNAMENT_ID])  [refetch]
  → isSaving indicator shown during mutation
  → saveError toast shown on failure
```

On page load:
```
TournamentPage mounts
  → useQuery fetches getTournament(TOURNAMENT_ID)
  → on success: useTournamentStore.setState(cloudData)
  → components render from Zustand (no prop drilling of cloud data)
```

---

## 5. Out of Scope

- `listTournaments` / browse past tournaments UI
- Tournament ID generation (fixed constant for single tournament)
- Pair editing / tournament creation flow
- Player stats integration (tournament wins not counted in player career stats)
