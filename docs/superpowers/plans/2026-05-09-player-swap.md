# Player Swap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow any viewer of a shared session to do a permanent two-way player swap between any two unplayed games, persisted to the cloud so standings and scores stay correct.

**Architecture:** A pure `applySwap` utility swaps player IDs between two `ScheduleSlot` entries. `SummaryModal` gains a swap mode (toolbar button → selectable chips → confirmation dialog). `SharedSessionPage` adds a `swapPlayers` mutation using the same optimistic TanStack Query pattern as `togglePlayed` and `setScore`.

**Tech Stack:** React 19, TypeScript, TanStack Query, Tailwind v4

---

### Task 1: Create `src/utils/swap.ts`

**Files:**
- Create: `src/utils/swap.ts`

- [ ] **Step 1: Create the file with `SwapTarget` type and `applySwap` function**

```ts
// src/utils/swap.ts
import type { ScheduleSlot } from '../store'

export interface SwapTarget {
  slot: number
  court: number
  playerId: string
  team: 'A' | 'B'
  index: 0 | 1
}

export function applySwap(
  schedule: ScheduleSlot[],
  t1: SwapTarget,
  t2: SwapTarget,
): ScheduleSlot[] {
  return schedule.map((s) => {
    if (s.slot === t1.slot && s.court === t1.court) {
      const teamA = [...s.teamA] as [string, string]
      const teamB = [...s.teamB] as [string, string]
      if (t1.team === 'A') teamA[t1.index] = t2.playerId
      else teamB[t1.index] = t2.playerId
      return { ...s, teamA, teamB }
    }
    if (s.slot === t2.slot && s.court === t2.court) {
      const teamA = [...s.teamA] as [string, string]
      const teamB = [...s.teamB] as [string, string]
      if (t2.team === 'A') teamA[t2.index] = t1.playerId
      else teamB[t2.index] = t1.playerId
      return { ...s, teamA, teamB }
    }
    return s
  })
}
```

- [ ] **Step 2: Verify TypeScript compiles**

Run: `npm run build`
Expected: exits with code 0, no type errors

- [ ] **Step 3: Commit**

```bash
git add src/utils/swap.ts
git commit -m "feat: add applySwap utility and SwapTarget type"
```

---

### Task 2: Update `SummaryModal` — swap mode UI

**Files:**
- Modify: `src/components/SummaryModal.tsx`

- [ ] **Step 1: Add import for `SwapTarget`**

At line 1 of `src/components/SummaryModal.tsx`, after the existing imports, add:

```ts
import type { SwapTarget } from '../utils/swap'
```

- [ ] **Step 2: Add `onSwapPlayers` to props type and destructuring**

Find the props type block and add the new prop after `standalone`:

```ts
  saving?: boolean
  standalone?: boolean
  onSwapPlayers?: (t1: SwapTarget, t2: SwapTarget) => void
```

Add it to the destructured props after `standalone = false`:

```ts
  saving = false,
  standalone = false,
  onSwapPlayers,
```

- [ ] **Step 3: Add swap state and handlers after the existing `useState` declarations**

After the line:
```ts
const [draftScores, setDraftScores] = useState<Record<string, { a: string; b: string }>>({})
```

Add:

```ts
  const [swapMode, setSwapMode] = useState(false)
  const [swapSelected, setSwapSelected] = useState<SwapTarget | null>(null)
  const [swapError, setSwapError] = useState<string | null>(null)
  const [pendingSwap, setPendingSwap] = useState<{ t1: SwapTarget; t2: SwapTarget } | null>(null)

  function exitSwapMode() {
    setSwapMode(false)
    setSwapSelected(null)
    setSwapError(null)
    setPendingSwap(null)
  }

  function handleChipClick(target: SwapTarget) {
    if (!swapMode) return
    if (!swapSelected) {
      setSwapSelected(target)
      setSwapError(null)
      return
    }
    // Tap same chip again → deselect
    if (
      swapSelected.slot === target.slot &&
      swapSelected.court === target.court &&
      swapSelected.playerId === target.playerId
    ) {
      setSwapSelected(null)
      setSwapError(null)
      return
    }
    // Same game → error
    if (swapSelected.slot === target.slot && swapSelected.court === target.court) {
      setSwapError('Cannot swap players in the same game')
      setSwapSelected(null)
      return
    }
    setSwapError(null)
    setPendingSwap({ t1: swapSelected, t2: target })
    setSwapSelected(null)
  }
```

- [ ] **Step 4: Replace the toolbar div**

Find the entire toolbar div (starts with `{/* Toolbar */}` comment, contains Schedule/Standings tab buttons and optional Close button). Replace the full block with:

```tsx
      {/* Toolbar */}
      <div className="flex items-center justify-between px-5 py-3 border-b border-slate-800 shrink-0">
        <div className="flex items-center gap-3">
          <div className="flex gap-1">
            <button
              onClick={() => { setActiveTab('schedule'); exitSwapMode() }}
              className={`text-xs font-semibold px-3 py-1.5 rounded-lg transition-colors ${activeTab === 'schedule' ? 'bg-indigo-900/60 border border-indigo-700 text-indigo-300' : 'text-slate-500 hover:text-slate-300'}`}
            >
              Schedule
            </button>
            <button
              onClick={() => { setActiveTab('standings'); exitSwapMode() }}
              className={`text-xs font-semibold px-3 py-1.5 rounded-lg transition-colors ${activeTab === 'standings' ? 'bg-indigo-900/60 border border-indigo-700 text-indigo-300' : 'text-slate-500 hover:text-slate-300'}`}
            >
              Standings
            </button>
          </div>
          {playedCount > 0 && (
            <span className="text-xs text-slate-500">
              {playedCount}/{totalGames} played
            </span>
          )}
        </div>
        <div className="flex items-center gap-2">
          {onSwapPlayers && activeTab === 'schedule' && (
            swapMode ? (
              <button
                onClick={exitSwapMode}
                className="text-xs font-semibold px-3 py-1.5 rounded-lg bg-slate-800 border border-slate-600 text-slate-300 hover:text-white transition-colors"
              >
                ✕ Cancel
              </button>
            ) : (
              <button
                onClick={() => setSwapMode(true)}
                className="text-xs font-semibold px-3 py-1.5 rounded-lg bg-indigo-900/20 border border-indigo-800/50 text-indigo-400 hover:text-indigo-300 transition-colors"
              >
                ⇄ Swap
              </button>
            )
          )}
          {onClose && (
            <button
              onClick={onClose}
              className="text-slate-400 hover:text-white px-3 py-1.5 rounded-lg hover:bg-slate-800 transition-colors text-sm"
            >
              Close
            </button>
          )}
        </div>
      </div>
```

- [ ] **Step 5: Add hint banner inside the content `<div>`**

Find the line:
```tsx
      <div className="flex-1 overflow-auto px-4 py-4 max-w-xl mx-auto w-full">
```

Replace it with (adds the hint banner as the first child):

```tsx
      <div className="flex-1 overflow-auto px-4 py-4 max-w-xl mx-auto w-full">
        {swapMode && (
          <div className="mb-3 rounded-lg bg-indigo-950/50 border border-indigo-800/40 px-3 py-2 flex flex-col gap-1">
            <span className="text-xs text-indigo-300 font-medium">
              {swapSelected
                ? '1 of 2 selected — tap a player from a different game'
                : 'Select two players from different games to swap'}
            </span>
            {swapError && (
              <span className="text-[11px] text-red-400">{swapError}</span>
            )}
          </div>
        )}
```

- [ ] **Step 6: Replace the team name rendering inside the game grid**

Find this block inside the game row (inside the `{games.map((g) => { ... })}` loop):

```tsx
                          <div className="grid items-center gap-2 flex-1 min-w-0" style={{ gridTemplateColumns: 'auto 1fr auto 1fr' }}>
                            <span className="text-[10px] font-semibold text-slate-600 whitespace-nowrap">
                              {courtLabel(g.court)}
                            </span>
                            <span className={`text-xs font-medium ${done ? 'text-slate-400 line-through' : 'text-white'}`}>
                              {name(g.teamA[0], s)} &amp; {name(g.teamA[1], s)}
                            </span>
                            <span className="text-slate-600 text-xs text-center">vs</span>
                            <span className={`text-xs font-medium ${done ? 'text-slate-400 line-through' : 'text-white'}`}>
                              {name(g.teamB[0], s)} &amp; {name(g.teamB[1], s)}
                            </span>
                          </div>
```

Replace with:

```tsx
                          <div className="grid items-center gap-2 flex-1 min-w-0" style={{ gridTemplateColumns: 'auto 1fr auto 1fr' }}>
                            <span className="text-[10px] font-semibold text-slate-600 whitespace-nowrap">
                              {courtLabel(g.court)}
                            </span>
                            <div className="flex items-center gap-1 min-w-0">
                              {([0, 1] as const).map((i) => {
                                const id = g.teamA[i]
                                const n = name(id, s)
                                const target: SwapTarget = { slot: s, court: g.court, playerId: id, team: 'A', index: i }
                                const isSelected = swapSelected?.slot === s && swapSelected?.court === g.court && swapSelected?.playerId === id
                                return (
                                  <span key={i} className="flex items-center gap-1">
                                    {i > 0 && <span className="text-[10px] text-slate-600">&amp;</span>}
                                    {swapMode && !done ? (
                                      <button
                                        onClick={() => handleChipClick(target)}
                                        className={`text-xs font-medium px-1.5 py-0.5 rounded-md border transition-colors ${
                                          isSelected
                                            ? 'bg-indigo-900/50 border-indigo-500 text-indigo-200 ring-1 ring-indigo-500/60'
                                            : 'bg-slate-800/60 border-slate-600 text-slate-200 hover:border-indigo-400 hover:text-indigo-200'
                                        }`}
                                      >
                                        {n}
                                      </button>
                                    ) : (
                                      <span className={`text-xs font-medium ${done ? 'text-slate-400 line-through' : 'text-white'}`}>{n}</span>
                                    )}
                                  </span>
                                )
                              })}
                            </div>
                            <span className="text-slate-600 text-xs text-center">vs</span>
                            <div className="flex items-center gap-1 min-w-0">
                              {([0, 1] as const).map((i) => {
                                const id = g.teamB[i]
                                const n = name(id, s)
                                const target: SwapTarget = { slot: s, court: g.court, playerId: id, team: 'B', index: i }
                                const isSelected = swapSelected?.slot === s && swapSelected?.court === g.court && swapSelected?.playerId === id
                                return (
                                  <span key={i} className="flex items-center gap-1">
                                    {i > 0 && <span className="text-[10px] text-slate-600">&amp;</span>}
                                    {swapMode && !done ? (
                                      <button
                                        onClick={() => handleChipClick(target)}
                                        className={`text-xs font-medium px-1.5 py-0.5 rounded-md border transition-colors ${
                                          isSelected
                                            ? 'bg-indigo-900/50 border-indigo-500 text-indigo-200 ring-1 ring-indigo-500/60'
                                            : 'bg-slate-800/60 border-slate-600 text-slate-200 hover:border-indigo-400 hover:text-indigo-200'
                                        }`}
                                      >
                                        {n}
                                      </button>
                                    ) : (
                                      <span className={`text-xs font-medium ${done ? 'text-slate-400 line-through' : 'text-white'}`}>{n}</span>
                                    )}
                                  </span>
                                )
                              })}
                            </div>
                          </div>
```

- [ ] **Step 7: Add confirmation dialog overlay**

Find the opening return statement:
```tsx
  return (
    <div className={standalone ? 'flex-1 overflow-auto flex flex-col bg-slate-950' : 'fixed inset-0 z-50 bg-slate-950 overflow-auto flex flex-col'}>
```

Add the confirmation dialog as the **first child** inside that outer div (before the `{/* Toolbar */}` comment):

```tsx
      {pendingSwap && (
        <div className="fixed inset-0 z-[70] flex items-center justify-center bg-slate-950/80 px-6">
          <div className="bg-slate-900 border border-slate-700 rounded-2xl p-5 w-full max-w-xs text-center flex flex-col gap-3">
            <p className="text-sm font-bold text-white">Confirm Swap</p>
            <p className="text-xs text-slate-400 leading-relaxed">
              <span className="text-indigo-200 font-semibold">{playerMap.get(pendingSwap.t1.playerId)?.name}</span>
              {' '}(Slot {pendingSwap.t1.slot + 1}, Court {courtLabel(pendingSwap.t1.court)})
              {' '}⇄{' '}
              <span className="text-indigo-200 font-semibold">{playerMap.get(pendingSwap.t2.playerId)?.name}</span>
              {' '}(Slot {pendingSwap.t2.slot + 1}, Court {courtLabel(pendingSwap.t2.court)})
            </p>
            <p className="text-[11px] text-red-400">⚠ This cannot be undone.</p>
            <div className="flex gap-2">
              <button
                onClick={() => setPendingSwap(null)}
                className="flex-1 text-xs font-semibold py-2 rounded-lg bg-slate-800 border border-slate-600 text-slate-300 hover:text-white transition-colors"
              >
                Cancel
              </button>
              <button
                onClick={() => {
                  onSwapPlayers!(pendingSwap.t1, pendingSwap.t2)
                  exitSwapMode()
                }}
                disabled={saving}
                className="flex-1 text-xs font-bold py-2 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white transition-colors disabled:opacity-50"
              >
                {saving ? 'Saving…' : 'Confirm Swap'}
              </button>
            </div>
          </div>
        </div>
      )}
```

- [ ] **Step 8: Verify TypeScript compiles**

Run: `npm run build`
Expected: exits with code 0, no errors

- [ ] **Step 9: Manual smoke test**

Run: `npm run dev`

Open a shared session URL (or local dev equivalent). Verify:
- "⇄ Swap" button appears in the Schedule tab toolbar
- Tapping it shows the hint banner and makes player names into buttons
- Tapping a played game's player does nothing (chip is not a button)
- Tapping the same player twice deselects it
- Tapping two players from the same game shows the error message
- Tapping two players from different games shows the confirmation dialog with correct names and slots
- "Cancel" on the dialog dismisses it and clears selection
- "✕ Cancel" in the toolbar exits swap mode entirely
- Switching to Standings tab exits swap mode

- [ ] **Step 10: Commit**

```bash
git add src/components/SummaryModal.tsx
git commit -m "feat: add swap mode UI to SummaryModal"
```

---

### Task 3: Wire up mutation in `SharedSessionPage`

**Files:**
- Modify: `src/pages/SharedSessionPage.tsx`

- [ ] **Step 1: Add imports**

In `src/pages/SharedSessionPage.tsx`, find the existing import line:
```ts
import { getSession, publishSession, type CloudSnapshot } from '../utils/cloudSync'
```

Add a new import line after it:
```ts
import { applySwap, type SwapTarget } from '../utils/swap'
```

- [ ] **Step 2: Add `swapPlayers` mutation after the `setScore` mutation block**

After the closing `})` of the `setScore` mutation, add:

```ts
  const swapPlayers = useMutation({
    mutationFn: async ({ t1, t2 }: { t1: SwapTarget; t2: SwapTarget }) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const nextSchedule = applySwap(current.schedule, t1, t2)
      const updated: CloudSnapshot = { ...current, schedule: nextSchedule }
      await publishSession(sessionId!, updated)
      return updated
    },
    onMutate: async ({ t1, t2 }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return { ...old, schedule: applySwap(old.schedule, t1, t2) }
      })
      return { previous }
    },
    onSuccess: () => setSaveError(null),
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['session', sessionId], context?.previous)
      setSaveError('Failed to save, please try again')
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
    },
  })
```

- [ ] **Step 3: Include `swapPlayers` in `isSaving`**

Find:
```ts
  const isSaving = togglePlayed.isPending || setScore.isPending
```
Replace with:
```ts
  const isSaving = togglePlayed.isPending || setScore.isPending || swapPlayers.isPending
```

- [ ] **Step 4: Pass `onSwapPlayers` to `SummaryModal`**

Find `saving={isSaving}` inside the `<SummaryModal` JSX and add the new prop on the next line:

```tsx
        saving={isSaving}
        onSwapPlayers={(t1, t2) => swapPlayers.mutate({ t1, t2 })}
```

- [ ] **Step 5: Verify TypeScript compiles**

Run: `npm run build`
Expected: exits with code 0, no errors

- [ ] **Step 6: End-to-end manual test**

Run: `npm run dev`

Open a shared session. Do a full swap:
1. Tap "⇄ Swap", select two players from different unplayed games, confirm
2. Verify the schedule row updates immediately (optimistic) with the new player names
3. Reload the page — verify the swap persisted (schedule still shows swapped names)
4. Enter a score for the swapped game — verify Standings attributes it to the swapped-in player, not the original

- [ ] **Step 7: Commit**

```bash
git add src/pages/SharedSessionPage.tsx
git commit -m "feat: wire swapPlayers mutation in SharedSessionPage"
```
