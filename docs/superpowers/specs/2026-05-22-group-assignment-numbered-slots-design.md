# Group Assignment — Numbered Slots Design

## Overview

Redesign the `GroupAssignment` component to show numbered slots (#1–#16) directly in the group cards. Interaction flips from "tap pair → pick group" to "tap slot → pick pair". No modal/bottom-sheet needed.

## Slot Numbering

Slots are globally numbered 1–16, grouped by 4:
- Group A: slots #1–#4
- Group B: slots #5–#8
- Group C: slots #9–#12
- Group D: slots #13–#16

The slot number maps directly to the pair's seeding position in the group (slot #1 = Group A seed 1, slot #5 = Group B seed 1, etc.). This numbering is purely visual — the underlying data model stays the same (`groups: Record<GroupId, string[]>` where index 0–3 maps to slot 1–4 within the group).

## Interaction Flow

### Default state (no slot selected)
- 2×2 group grid displayed at the top, same layout as today
- Each group card has 4 slot rows inside it
- Filled slots: show `#N · PairName` + a `×` remove button
- Empty slots: show `#N · tap to fill` in muted style with a dashed border
- Unassigned pairs pool shown below as chips (same as today)
- Hint text: "Tap an empty slot, then tap a pair to assign"

### Slot selected state
- User taps an empty slot → that slot highlights in amber (yellow border + light background)
- Pool label changes to: "Slot #N · Group X selected — pick a pair:"
- All pair chips in the pool turn gold/selectable style
- User taps a pair chip → pair is placed into the highlighted slot; selection clears
- User taps the same active slot again (or taps elsewhere outside a pair chip) → deselects, returns to default state
- Filled slots are not tappable for selection (only their `×` button works)

### Remove a pair
- Tap the `×` button on a filled slot → calls `onRemovePairFromGroup(pairId)` and the slot returns to empty state
- Works the same regardless of whether another slot is currently selected

### Confirm groups
- Confirm button appears (same as today) when all 16 slots are filled (`allFull`)

## Component Changes

**`GroupAssignment.tsx`**

State: replace `picking: string | null` (which pairId is being picked) with `activeSlot: { groupId: GroupId; slotIndex: number } | null` (which slot is selected).

Slot rendering: each group card renders 4 rows instead of variable-height filled items + a "slots left" summary. Slot index within group (0–3) maps to global slot number: `(groupIndex × 4) + slotIndex + 1` where `groupIndex` is `GROUP_IDS.indexOf(groupId)`.

Pool chip rendering: when `activeSlot` is set, chips render with the gold/selectable style. Tapping a chip calls `onAddPairToGroup(pairId, activeSlot.groupId)` then clears `activeSlot`.

Remove the bottom-sheet modal entirely — it is no longer needed.

## Visual Design

Consistent with existing dark slate theme:
- Empty slot: `bg-slate-900 border border-dashed border-slate-700`
- Active slot: `bg-amber-50/10 border border-amber-400 ring-2 ring-amber-400/30` with amber text
- Slot number label: `text-slate-500 text-[8px] font-bold min-w-[18px]`
- Pool chips (default): `bg-slate-700 text-slate-300 border border-slate-600`
- Pool chips (selectable): `bg-slate-900 text-yellow-300 border border-yellow-400 font-semibold`
- Group header colors unchanged: A=amber-900/yellow-300, B=blue-900/blue-300, C=green-900/green-300, D=purple-900/purple-300

## Out of Scope

- No changes to the data model (`TournamentPair`, `groups`, store actions)
- No changes to `GroupMatches`, `BracketTab`, `StandingsTab`, or any other component
- No drag-and-drop
- Slot numbers are display-only and do not affect bracket seeding logic
