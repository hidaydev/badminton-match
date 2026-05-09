# Player Absence Tagging — Design Spec

## Goal

Allow any viewer of a shared session to mark one or more players as absent. Absent players are visually tagged in the schedule and excluded from standings. The tag is toggleable (can be undone), but does not reverse any swaps that may have been performed while a player was marked absent.

## Architecture

Absence is a pure tag stored as a list of player IDs on the `CloudSnapshot`. It has no effect on the schedule structure — chips remain in their slots, just visually marked. Standings computation filters out absent players. The existing TanStack Query optimistic mutation pattern handles persistence.

## Data

Add `absentPlayers: string[]` to `CloudSnapshot` (default: `[]`). Values are player IDs. Persisted to cloud via `publishSession`, same as `playedGames` and `gameScores`.

`CloudSnapshot` change:
```ts
absentPlayers: string[]  // player IDs, default []
```

## UI — Absent Mode

Available only in `SummaryModal` standalone mode (shared session), schedule tab only. Swap and Absent modes are mutually exclusive — entering one hides the other's button.

**Toolbar button:** `👤 Absent` (idle) → `✕ Cancel` (active), same styling pattern as the Swap button.

**Player picker banner** (replaces hint area, same as swap mode hint):
- Shows all players as chips
- Already-absent players rendered pre-selected (red tint)
- Multi-select: tap to toggle; tapping a pre-selected chip deselects it
- Hint text: `"Tap players to mark absent — N selected"` (updates live as selections change)

**Live schedule preview:** As players are selected, their chips in the schedule immediately show the absent style (red tint + strikethrough). Non-selected chips dim (same `opacity-30` dimming as swap pending state).

**Confirm bar** (appears as soon as ≥1 player is toggled from their current state):
- Text: `"Alice, Dave — absent"` (or `"Alice — removing absent"` if deselecting)
- Sub-text: `"Excluded from standings"`
- ✕ button: discards all pending changes, exits absent mode
- Confirm button: saves updated `absentPlayers` to cloud, exits mode

**Cancel (toolbar):** Discards pending changes, exits mode.

## Absent chip style (schedule)

Absent player chips throughout the schedule:
- Background: red-tinted (`bg-red-950/60`)
- Border: `border-red-800/60`
- Text: `text-red-300` + `line-through`

Applied whenever `absentPlayers` includes the player's ID, regardless of mode.

## Standings

`StandingsTab` receives `absentPlayers: string[]` as a new prop. Filters out absent players before rendering — they do not appear in the standings list at all.

`computeStandings` already accepts a `players` array — caller simply filters before passing.

## Mutation (SharedSessionPage)

New `setAbsent` mutation following the same optimistic pattern as `togglePlayed`:

```ts
mutationFn: async ({ nextAbsent }: { nextAbsent: string[] }) => {
  const current = queryClient.getQueryData<CloudSnapshot>(...)
  if (!current) throw new Error('no data')
  const updated = { ...current, absentPlayers: nextAbsent }
  await publishSession(sessionId!, updated)
  return updated
}
```

`isSaving` includes `setAbsent.isPending`.

`SummaryModal` receives `absentPlayers`, `onSetAbsent` props.

## Behaviour Notes

- Un-marking absent simply removes the player ID from `absentPlayers`. If swaps already moved that player out of games, those swaps remain — un-marking does not restore the original schedule.
- Absent mode and swap mode cannot be active simultaneously.
- The Absent button is hidden when swap mode is active; the Swap button is hidden when absent mode is active.
- Played-game checkboxes and score buttons remain interactive during absent mode (unlike swap mode).
- If `absentPlayers` is missing from a legacy snapshot, treat as `[]`.
