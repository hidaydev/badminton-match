# Player Action Menu — Design Spec

**Date:** 2026-05-16

## Overview

Replace the two separate toolbar buttons (Absent, Swap) in `SummaryModal` with a single "⋯ Actions" dropdown button. Add a third action: Replace player. The dropdown lists all three actions; selecting one enters the corresponding mode.

## Toolbar Change

**Before:** Two buttons visible at once — `👤 Absent` and `⇄ Swap`

**After:** One button `⋯ Actions` that opens a dropdown with:
- ⇄ Swap players
- 👤 Mark absent
- ↔ Replace player

The dropdown closes when an action is selected, when the user taps outside, or when Cancel is pressed. Only one mode (swap / absent / replace) can be active at a time — entering one exits any currently active mode.

## Replace Player Feature

### UX Flow

1. User opens dropdown → taps "↔ Replace player"
2. A green banner appears below the toolbar: `"Tap a player to replace"`
3. User taps any player chip in the schedule — a name input appears in the banner:
   `Replace [PlayerName] with: [___________] [✓ Save]`
4. User types a new name → taps Save
5. The player's `name` field is updated in `snapshot.players` — the schedule now displays the new name everywhere that player appears. The player's ID and slot assignments are unchanged.
6. Replace mode exits automatically after a successful save.

Cancel button exits replace mode without saving.

### Data Model

No new fields needed. The mutation updates `player.name` in `snapshot.players` in place — the same array that's already in `CloudSnapshot`. The schedule references player IDs, so renaming is purely a display change with no structural impact.

No existing-player detection or ID swapping. If the user types a name that happens to match another player, it's allowed — treated as a rename.

### New Mutation: `useReplacePlayer`

Add to `src/queries/sessions.ts`:

```ts
useReplacePlayer(sessionId: string)
// vars: { playerId: string; newName: string }
// Finds player by ID in snapshot.players, updates name, publishes snapshot.
// Optimistic update + rollback on error, same pattern as existing mutations.
```

Export from `src/queries/index.ts`.

### SummaryModal Props

Add two new optional props:

```ts
onReplacePlayer?: (playerId: string, newName: string) => void
```

`SharedSessionPage` wires up `useReplacePlayer` and passes `onReplacePlayer`. `GeneratePage` (local session) does not pass this prop — replace is a cloud-only feature since local sessions don't persist.

### UI State (inside SummaryModal)

```ts
const [replaceMode, setReplaceMode] = useState(false)
const [replaceTarget, setReplaceTarget] = useState<string | null>(null)  // playerId
const [replaceName, setReplaceName] = useState('')
```

- Entering replace mode calls `exitSwapMode()` and `exitAbsentMode()` (same guard pattern as existing modes).
- Player chips in replace mode render as tappable buttons (same visual treatment as swap mode chips).
- Tapping a chip sets `replaceTarget` — banner switches to show the name input.
- Tapping the same chip again deselects it (back to "tap a player" state).
- Save is disabled if `replaceName.trim()` is empty.

### Visual Treatment

- Replace mode banner: green (`bg-emerald-950/30 border border-emerald-900/40`), matching absent mode's red but in green.
- Player chips in replace mode: green hover ring (`hover:border-emerald-400`).
- Selected chip: `bg-emerald-900/50 border-emerald-500 text-emerald-200 ring-1 ring-emerald-500/60`.
- After save: player name updates immediately via optimistic update.

## Dropdown Implementation

Rendered inline in the toolbar using a `useState<boolean>` open/close toggle. A transparent full-screen backdrop `div` closes it on outside click. No external library needed.

Position: `absolute right-0 top-full mt-1` — anchored below the Actions button, right-aligned.

The dropdown is hidden when a mode is active (swap / absent / replace) — the button becomes a Cancel button instead, same as the current per-button cancel pattern.

## Files Affected

- `src/queries/sessions.ts` — add `useReplacePlayer`
- `src/queries/index.ts` — export `useReplacePlayer`
- `src/components/SummaryModal.tsx` — add dropdown, replace mode UI, `onReplacePlayer` prop
- `src/pages/SharedSessionPage.tsx` — wire up `useReplacePlayer`, pass `onReplacePlayer`
