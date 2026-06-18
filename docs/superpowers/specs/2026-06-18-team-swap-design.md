# Team Swap Feature

**Date:** 2026-06-18  
**Status:** Approved

## Overview

Allow swapping an entire team (both players) between two games in one action, instead of swapping players one by one. Use case: two players want to be on the same team in an early game but their partner hasn't arrived yet.

## New Types & Utilities

### `src/utils/swap.ts` — additions

```ts
export interface TeamSwapTarget {
  slot: number
  court: number
  team: 'A' | 'B'
}
```

**`applyTeamSwap(schedule, t1, t2)`** — swaps the full `[string, string]` team array between the two games:
- Find `game1` and `game2` from schedule
- Capture `team1Players` and `team2Players`
- Return new schedule where game1's selected team gets `team2Players` and game2's selected team gets `team1Players`

**`detectTeamSwapConflict(schedule, t1, t2)`** — returns a conflicting player ID or null:
- `team1Players` moving to game2: check each player against game2's *other* team
- `team2Players` moving to game1: check each player against game1's *other* team

## Session Snapshot

### `src/utils/sessionSnapshot.ts` — addition

```ts
export function swapTeamsInSnapshot(snapshot, t1, t2): CloudSnapshot {
  return { ...snapshot, schedule: applyTeamSwap(snapshot.schedule, t1, t2) }
}
```

No score/playedGames migration needed — team swaps don't move games between slots.

## Query Layer

### `src/queries/sessions.ts` — addition

`useSwapTeams(sessionId)` mutation — mirrors `useSwapPlayers` exactly:
- Optimistic update via `swapTeamsInSnapshot`
- Rollback on error
- Invalidate session query on settle

## SummaryModal Changes

### New prop

```ts
onSwapTeams?: (t1: TeamSwapTarget, t2: TeamSwapTarget) => void
```

### New state

```ts
const [teamSwapMode, setTeamSwapMode] = useState(false)
const [teamSwapSelected, setTeamSwapSelected] = useState<TeamSwapTarget | null>(null)
const [pendingTeamSwap, setPendingTeamSwap] = useState<{ t1: TeamSwapTarget; t2: TeamSwapTarget } | null>(null)
const [teamSwapError, setTeamSwapError] = useState<string | null>(null)
```

### Actions menu

Add entry when `onSwapTeams` is defined:
```
↔ Swap team
```

### Game row — team swap mode

In team swap mode, each team section (the player name area for Team A and Team B) becomes a tappable button. Tapping selects that `TeamSwapTarget`.

**Interaction flow:**
1. Tap first team → `teamSwapSelected` set, team highlighted in amber
2. Tap same team again → deselect
3. Tap different team → run `detectTeamSwapConflict`:
   - Conflict found → set `teamSwapError`, clear selection
   - No conflict → set `pendingTeamSwap`, clear selection

### Confirm bar

Same pattern as player swap confirm bar — fixed to bottom, shows:
> "Swap [Name1] & [Name2] ↔ [Name3] & [Name4]?"

Buttons: **Confirm** (amber) | **Cancel**

On confirm: call `onSwapTeams(t1, t2)` then `exitTeamSwapMode()`.

### Exit function

`exitTeamSwapMode()` resets all four team swap states.

## SharedSessionPage Changes

Wire up the new prop:

```tsx
onSwapTeams={(t1, t2) => swapTeams({ t1, t2 }, {
  onError: () => { /* show error */ }
})}
```

Where `swapTeams` is destructured from `useSwapTeams(sessionId)`.
