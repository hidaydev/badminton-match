# Switch Slot — Design Spec

**Date:** 2026-05-16

## Overview

Add a "↕ Switch slot" action to the Actions dropdown in `SummaryModal`. In switch slot mode, every game row shows a drag handle (≡). The user drags one game and drops it onto another — the two games exchange their `{slot, court}` position in the schedule while their player assignments stay intact. Conflict detection prevents a drop that would put the same player in two games within the same time slot.

## Where It Lives

Fourth item in the existing "⋯ Actions" dropdown (after Replace player):

```
⇄ Swap players
👤 Mark absent
↔ Replace player
↕ Switch slot      ← new
```

Entering switch slot mode exits all other active modes (swap / absent / replace), same pattern as existing modes. The toolbar shows "✕ Cancel" while active.

## UX Flow

1. User opens Actions dropdown → taps "↕ Switch slot"
2. An orange banner appears: `"↕ Drag ≡ to switch a game's slot · ✕ Cancel"`
3. Every game row shows a drag handle `⠿` on its left edge
4. User long-press/drags a game — the dragged game lifts slightly (shadow), the hovered drop target highlights with an orange dashed border
5. User releases onto a target game:
   - **Valid drop** → confirm bar slides up from the bottom showing both game labels and "⚠ Cannot be undone" — user taps Confirm or ✕ Cancel
   - **Conflict** → error toast shown: `"Can't switch — [Player] already plays in Slot X"` — drag snaps back, no confirm bar
6. On Confirm → mutation fires, schedule updates optimistically, switch slot mode exits

Cross-court swaps are allowed: Slot 1 Court A ↔ Slot 2 Court B is valid as long as no player conflict exists.

## Conflict Detection

Before showing the confirm bar, check: after swapping `{slot, court}` of game1 and game2, does any player appear in more than one game in the same slot?

```ts
function detectSlotSwapConflict(
  schedule: ScheduleSlot[],
  g1: { slot: number; court: number },
  g2: { slot: number; court: number },
): string | null  // returns conflicting player ID, or null if safe
```

Logic:
- Find game1 and game2 in schedule
- All players in game1 will move to game2's slot — check if any of them already appear in another game in that slot (excluding game2 itself)
- All players in game2 will move to game1's slot — check if any of them already appear in another game in that slot (excluding game1 itself)
- Return the first conflicting player ID found, or `null` if safe

## Data Model

No new fields in `CloudSnapshot`. The mutation swaps `slot` and `court` between two `ScheduleSlot` objects, keeping `teamA` and `teamB` intact.

```ts
// src/utils/slotSwap.ts (new file)
export interface SlotSwapTarget {
  slot: number
  court: number
}

export function applySlotSwap(
  schedule: ScheduleSlot[],
  g1: SlotSwapTarget,
  g2: SlotSwapTarget,
): ScheduleSlot[]

export function detectSlotSwapConflict(
  schedule: ScheduleSlot[],
  g1: SlotSwapTarget,
  g2: SlotSwapTarget,
): string | null  // conflicting player ID or null
```

`applySlotSwap` maps over the schedule: when it finds a game matching g1's `{slot, court}`, it returns it with g2's `{slot, court}` (and vice versa). All other games are unchanged.

## New Mutation: `useSwapSlots`

Add to `src/queries/sessions.ts` following the existing optimistic-update pattern:

```ts
useSwapSlots(sessionId: string)
// vars: { g1: SlotSwapTarget; g2: SlotSwapTarget }
// Applies applySlotSwap to snapshot.schedule, publishes, optimistic + rollback
```

Export from `src/queries/index.ts` via existing `export *`.

## Drag Implementation

Use `@dnd-kit/core` (new dependency). Key choices:
- `useSensor(TouchSensor, { activationConstraint: { delay: 200, tolerance: 5 } })` — 200ms hold distinguishes drag from scroll on mobile
- `useSensor(PointerSensor)` — for desktop/mouse
- Each game row is a `<Draggable>` with a dedicated drag handle element (not the whole row, to preserve scroll)
- Each game row is also a `<Droppable>` — drop targets highlight with an orange dashed border on hover

Switch slot mode wraps the schedule content in a `<DndContext>` with `onDragEnd` handler that:
1. Runs `detectSlotSwapConflict` — if conflict, shows error toast and returns
2. If safe, sets `pendingSlotSwap: { g1, g2 }` state → confirm bar renders

## SummaryModal Changes

New state:
```ts
const [slotSwapMode, setSlotSwapMode] = useState(false)
const [pendingSlotSwap, setPendingSlotSwap] = useState<{ g1: SlotSwapTarget; g2: SlotSwapTarget } | null>(null)
const [slotSwapError, setSlotSwapError] = useState<string | null>(null)
```

New helpers:
```ts
function exitSlotSwapMode() { setSlotSwapMode(false); setPendingSlotSwap(null); setSlotSwapError(null) }
function enterSlotSwapMode() { exitSwapMode(); exitAbsentMode(); exitReplaceMode(); setSlotSwapMode(true) }
```

New prop:
```ts
onSwapSlots?: (g1: SlotSwapTarget, g2: SlotSwapTarget) => void
```

Confirm bar (same pattern as existing swap confirm bar, orange-themed):
- Shows game labels: "Slot 1A (Ali & Budi) ↕ Slot 2A (Ismet & Joko)"
- ✕ Cancel / Confirm buttons
- On Confirm: calls `onSwapSlots?.(pendingSlotSwap.g1, pendingSlotSwap.g2)` then `exitSlotSwapMode()`

In switch slot mode: played checkbox and score toggle are disabled (same guards as swap/replace modes).

## SharedSessionPage Changes

Add `useSwapSlots` hook, pass `onSwapSlots` to `SummaryModal`. Same wiring pattern as `useSwapPlayers`.

## Files Affected

| File | Change |
|------|--------|
| `src/utils/slotSwap.ts` | New — `applySlotSwap`, `detectSlotSwapConflict`, `SlotSwapTarget` |
| `src/queries/sessions.ts` | Add `useSwapSlots` mutation |
| `src/components/SummaryModal.tsx` | Dropdown item, slot swap mode state, DndContext, drag handles, confirm bar, `onSwapSlots` prop |
| `src/pages/SharedSessionPage.tsx` | Wire `useSwapSlots`, pass `onSwapSlots` |
| `package.json` | Add `@dnd-kit/core` and `@dnd-kit/utilities` |
