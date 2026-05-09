# Player Swap Feature — Design Spec

**Date:** 2026-05-09  
**Status:** Approved

---

## Overview

Allow viewers of a shared session to swap two players between different games in the schedule. The primary use case is replacing an absent/late player by moving someone from another court into their spot, while keeping all games at 4 players via a mandatory two-way swap.

---

## Rules & Constraints

- **Two-way only** — swapping aaa ↔ hhh moves aaa into hhh's game AND hhh into aaa's game. One-way moves are not allowed.
- **Cross-game only** — both players must be from different games. Swapping within the same game is rejected with an inline error.
- **Unplayed games only** — players in games already marked as played are disabled and cannot be selected.
- **Any slot** — swaps are not restricted to the same time slot.
- **Permanent** — no undo. To reverse, the user must manually swap back.
- **Persisted to cloud** — the swap mutates the `schedule` array in `CloudSnapshot` and calls `publishSession`, ensuring standings and score history remain correct.
- **Shared view only** — feature is only present in `SharedSessionPage`, not in `GeneratePage`.
- **Any viewer** — no auth required; anyone with the shared link can swap.

---

## UX Flow

1. **Toolbar button** — a `⇄ Swap` button sits in the `SummaryModal` toolbar, visible only on the Schedule tab.
2. **Activate swap mode** — tapping `⇄ Swap` activates swap mode. The button changes to `✕ Cancel`. A hint banner appears below the toolbar: *"Select two players from different games to swap"*.
3. **Selectable chips** — all player name chips in unplayed games become tappable. Chips in played games are dimmed and non-interactive.
4. **Select Player 1** — tapping a chip highlights it with an indigo ring. A status line shows *"1 of 2 selected — now tap a player from a different game"*.
5. **Select Player 2** — tapping another chip from a **different** game triggers the confirmation dialog. Tapping a chip from the **same** game shows an inline error: *"Cannot swap players in the same game"*.
6. **Confirmation dialog** — a modal shows:
   - `[Player 1] (Slot X, Court Y) ⇄ [Player 2] (Slot X, Court Y)`
   - Warning: *"⚠ This cannot be undone."*
   - Cancel / Confirm Swap buttons.
7. **Execute** — on confirm, the schedule is updated optimistically in the query cache, `publishSession` is called, swap mode exits, and the schedule re-renders with the new lineup.
8. **Cancel** — tapping Cancel or `✕ Cancel` exits swap mode with no changes.

---

## Data Model

No new fields are added to `CloudSnapshot`. The swap directly mutates `schedule`:

```ts
// For each affected ScheduleSlot, find and replace the player ID in teamA or teamB
function applySwap(
  schedule: ScheduleSlot[],
  g1: { slot: number; court: number; playerId: string },
  g2: { slot: number; court: number; playerId: string }
): ScheduleSlot[]
```

- Find the slot where `slot === g1.slot && court === g1.court`, replace `g1.playerId` with `g2.playerId` in `teamA` or `teamB`.
- Do the same for g2 in the opposite slot/court.
- Return new schedule array (immutable update).

The updated schedule is published via `publishSession` using the same optimistic mutation pattern as `togglePlayed` and `setScore`.

---

## Components

### `SummaryModal` changes
- Accept optional `onSwapPlayers?: (g1: SwapTarget, g2: SwapTarget) => void` prop.
- When prop is provided, render `⇄ Swap` button in toolbar (Schedule tab only).
- Manage local swap state: `swapMode: boolean`, `selected: SwapTarget | null`.
- Render player chips as `<button>` elements in swap mode; disabled if game is played.
- Inline error state for same-game selection.

### `SwapTarget` type (new, internal to SummaryModal)
```ts
interface SwapTarget {
  slot: number
  court: number
  playerId: string
  team: 'A' | 'B'
  index: 0 | 1
}
```

### `SharedSessionPage` changes
- Add `swapPlayers` mutation (same pattern as `togglePlayed`/`setScore`).
- Pass `onSwapPlayers` to `SummaryModal`.
- The mutation calls `applySwap` on `snapshot.schedule`, then `publishSession`.

### `applySwap` utility (new, in `src/utils/swap.ts`)
- Pure function: `(schedule, target1, target2) => ScheduleSlot[]`
- No side effects; easy to unit test.

---

## Error Handling

| Scenario | Behaviour |
|---|---|
| Same-game selection | Inline error below hint banner; selection resets to step 1 |
| Network error on publish | Toast error (same as existing save error); optimistic update rolled back |
| Played game chip tapped | No-op (chip is disabled) |

---

## Out of Scope

- Undo / swap history log
- Swap in `GeneratePage` / local session view
- Restricting swaps to session owner
- Swapping more than two players in one action
