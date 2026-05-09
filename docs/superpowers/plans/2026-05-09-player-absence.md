# Player Absence Tagging — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "👤 Absent" mode to the shared session view that lets any viewer tag players as absent — excluded from standings and visually marked in the schedule — with full cloud persistence.

**Architecture:** `absentPlayers: string[]` (player IDs) is added to `CloudSnapshot` and persisted via `publishSession`. `SharedSessionPage` adds a `setAbsent` optimistic mutation and passes the absent list down to `SummaryModal`, which handles all absent-mode UI (toolbar button, player picker banner, confirm bar, chip styling) and filters absent players from the standings tab.

**Tech Stack:** React 19, TypeScript, TanStack Query optimistic mutations, Tailwind v4

---

## File Map

- **Modify** `src/utils/cloudSync.ts` — add `absentPlayers?: string[]` to `CloudSnapshot`
- **Modify** `src/pages/SharedSessionPage.tsx` — add `setAbsent` mutation, pass `absentPlayers` + `onSetAbsent` to `SummaryModal`
- **Modify** `src/components/SummaryModal.tsx` — absent mode UI, chip styling, standings filtering

---

### Task 1: Extend CloudSnapshot and wire mutation in SharedSessionPage

**Files:**
- Modify: `src/utils/cloudSync.ts`
- Modify: `src/pages/SharedSessionPage.tsx`

- [ ] **Step 1: Add `absentPlayers` to `CloudSnapshot`**

In `src/utils/cloudSync.ts`, add the optional field to the interface (optional so legacy snapshots without it don't break):

```ts
export interface CloudSnapshot {
  session: SessionConfig
  players: Player[]
  fixMatches: FixMatch[]
  schedule: ScheduleSlot[]
  playedGames: string[]
  gameScores: Record<string, GameScore>
  absentPlayers?: string[]   // ← add this line
}
```

- [ ] **Step 2: Add `setAbsent` mutation in `SharedSessionPage`**

In `src/pages/SharedSessionPage.tsx`, add the mutation after the `swapPlayers` mutation (around line 110). Follow the exact same optimistic pattern as `togglePlayed`:

```ts
const setAbsent = useMutation({
  mutationFn: async ({ nextAbsent }: { nextAbsent: string[] }) => {
    const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
    if (!current) throw new Error('no data')
    const updated: CloudSnapshot = { ...current, absentPlayers: nextAbsent }
    await publishSession(sessionId!, updated)
    return updated
  },
  onMutate: async ({ nextAbsent }) => {
    await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
    const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
    queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
      if (!old) return old
      return { ...old, absentPlayers: nextAbsent }
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

- [ ] **Step 3: Update `isSaving` and pass new props to `SummaryModal`**

Update `isSaving` to include `setAbsent.isPending`:

```ts
const isSaving = togglePlayed.isPending || setScore.isPending || swapPlayers.isPending || setAbsent.isPending
```

Add two props to the `<SummaryModal>` call (around line 172):

```tsx
absentPlayers={snapshot.absentPlayers ?? []}
onSetAbsent={(nextAbsent) => setAbsent.mutate({ nextAbsent })}
```

- [ ] **Step 4: Verify it compiles**

```bash
npm run build
```

Expected: no TypeScript errors. (The new props aren't yet accepted by SummaryModal — fix in Task 2.)

- [ ] **Step 5: Commit**

```bash
git add src/utils/cloudSync.ts src/pages/SharedSessionPage.tsx
git commit -m "feat: add absentPlayers to CloudSnapshot and setAbsent mutation"
```

---

### Task 2: Absent chip styling and standings exclusion

**Files:**
- Modify: `src/components/SummaryModal.tsx`

- [ ] **Step 1: Add `absentPlayers` and `onSetAbsent` props to `SummaryModal`**

In the props destructuring (around line 101), add:

```ts
absentPlayers = [] as string[],
onSetAbsent,
```

And in the props type:

```ts
absentPlayers?: string[]
onSetAbsent?: (nextAbsent: string[]) => void
```

- [ ] **Step 2: Add absent mode state**

After the existing swap state declarations (around line 150), add:

```ts
const [absentMode, setAbsentMode] = useState(false)
const [absentPending, setAbsentPending] = useState<Set<string>>(new Set())

function enterAbsentMode() {
  setAbsentPending(new Set(absentPlayers))
  setAbsentMode(true)
}

function exitAbsentMode() {
  setAbsentMode(false)
  setAbsentPending(new Set())
}
```

- [ ] **Step 3: Compute effective absent set for rendering**

Add this derived value after `exitAbsentMode` (used by both chip rendering and standings):

```ts
// In absent mode, preview pending selections; otherwise use saved state
const effectiveAbsent = absentMode ? absentPending : new Set(absentPlayers)

// True when pending state differs from saved state
const absentChanged = absentMode && (() => {
  const saved = new Set(absentPlayers)
  if (absentPending.size !== saved.size) return true
  for (const id of absentPending) if (!saved.has(id)) return true
  return false
})()
```

- [ ] **Step 4: Apply absent chip styling in the schedule**

In the schedule rendering, each player chip is rendered twice (once for teamA, once for teamB). For both, the chip is currently a `<span>` or `<button>` with classes like `text-xs font-medium px-1.5 py-0.5 rounded-md border`.

Find the non-swapMode chip (the `else` branch rendering a plain `<span>`, around line 413):

```tsx
<span className={`text-xs font-medium ${done ? 'text-slate-400 line-through' : 'text-white'}`}>{n}</span>
```

Replace with:

```tsx
<span className={`text-xs font-medium px-1.5 py-0.5 rounded-md border ${
  effectiveAbsent.has(id)
    ? 'bg-red-950/60 border-red-800/60 text-red-300 line-through'
    : done
      ? 'border-transparent text-slate-400 line-through'
      : 'border-transparent text-white'
}`}>{n}</span>
```

Do the same for the teamB equivalent `<span>` (around line 454).

Also update the swap-mode pending chip span (the `swapMode && !done && pendingSwap` branch) for both teamA and teamB to also respect absent styling for the non-selected case — replace `'border-transparent text-white'` with:

```tsx
effectiveAbsent.has(id)
  ? 'bg-red-950/60 border-red-800/60 text-red-300 line-through'
  : 'border-transparent text-white'
```

- [ ] **Step 5: Pass `absentPlayers` to `StandingsTab` and filter absent players**

`StandingsTab` currently receives all players. Add an `absentPlayerIds` prop and filter before computing standings.

Update the `StandingsTab` function signature:

```ts
function StandingsTab({
  players,
  schedule,
  gameScores,
  absentPlayerIds,
}: {
  players: Player[]
  schedule: import('../store').ScheduleSlot[]
  gameScores: Record<string, GameScore>
  absentPlayerIds: string[]
}) {
  const standings = computeStandings(
    players.filter(p => !absentPlayerIds.includes(p.id)),
    schedule,
    gameScores,
  )
```

Update the `<StandingsTab>` call (around line 336):

```tsx
<StandingsTab
  players={[...playerMap.values()]}
  schedule={result.schedule}
  gameScores={gameScores}
  absentPlayerIds={absentPlayers}
/>
```

- [ ] **Step 6: Verify it compiles**

```bash
npm run build
```

Expected: no TypeScript errors.

- [ ] **Step 7: Commit**

```bash
git add src/components/SummaryModal.tsx
git commit -m "feat: absent chip styling and standings exclusion"
```

---

### Task 3: Absent mode UI (toolbar button, player picker, confirm bar)

**Files:**
- Modify: `src/components/SummaryModal.tsx`

- [ ] **Step 1: Update toolbar — Absent and Swap buttons**

The toolbar currently shows the Swap button when `onSwapPlayers && activeTab === 'schedule'`. Replace that block (around line 272) with mutual exclusion logic:

```tsx
{onSetAbsent && activeTab === 'schedule' && !swapMode && (
  absentMode ? (
    <button
      onClick={exitAbsentMode}
      className="text-xs font-semibold px-3 py-1.5 rounded-lg bg-slate-800 border border-slate-600 text-slate-300 hover:text-white transition-colors"
    >
      ✕ Cancel
    </button>
  ) : (
    <button
      onClick={enterAbsentMode}
      className="text-xs font-semibold px-3 py-1.5 rounded-lg bg-red-950/30 border border-red-900/50 text-red-400 hover:text-red-300 transition-colors"
    >
      👤 Absent
    </button>
  )
)}
{onSwapPlayers && activeTab === 'schedule' && !absentMode && (
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
```

- [ ] **Step 2: Add player picker banner**

The swap hint banner is rendered at the top of the content area (around line 322):

```tsx
{swapMode && !pendingSwap && ( ... )}
```

Add the absent picker banner directly after it:

```tsx
{absentMode && (
  <div className="mb-3 rounded-lg bg-red-950/30 border border-red-900/40 px-3 py-2 flex flex-col gap-2">
    <span className="text-xs text-red-300 font-medium">
      {absentPending.size > 0
        ? `${absentPending.size} player${absentPending.size === 1 ? '' : 's'} marked absent — tap to toggle`
        : 'Tap players to mark absent'}
    </span>
    <div className="flex flex-wrap gap-1.5">
      {[...playerMap.values()].map((p) => {
        const isSelected = absentPending.has(p.id)
        return (
          <button
            key={p.id}
            onClick={() => {
              setAbsentPending((prev) => {
                const next = new Set(prev)
                if (next.has(p.id)) next.delete(p.id)
                else next.add(p.id)
                return next
              })
            }}
            className={`text-xs font-medium px-2 py-0.5 rounded-md border transition-colors ${
              isSelected
                ? 'bg-red-900/60 border-red-700 text-red-200'
                : 'bg-slate-800/60 border-slate-600 text-slate-300 hover:border-red-700 hover:text-red-300'
            }`}
          >
            {p.name}{isSelected ? ' ✓' : ''}
          </button>
        )
      })}
    </div>
  </div>
)}
```

- [ ] **Step 3: Add confirm bar for absent mode**

After the existing swap confirm bar (around line 534), add:

```tsx
{absentChanged && (
  <div className="shrink-0 border-t border-red-900/40 px-4 py-3 max-w-xl mx-auto w-full">
    <div className="bg-red-950/40 border border-red-800/50 rounded-xl px-3 py-2.5 flex items-center gap-3">
      <div className="flex-1 min-w-0">
        <p className="text-xs font-semibold text-slate-200 truncate">
          {absentPending.size === 0
            ? 'Remove all absent tags'
            : [...absentPending].map(id => playerMap.get(id)?.name ?? id).join(', ')}
        </p>
        <p className="text-[10px] text-slate-500 mt-0.5">Excluded from standings</p>
      </div>
      <button
        onClick={exitAbsentMode}
        className="text-xs text-slate-500 hover:text-slate-300 px-2 py-1.5 rounded-lg border border-slate-700 bg-slate-800/60 transition-colors shrink-0"
      >
        ✕
      </button>
      <button
        onClick={() => {
          onSetAbsent?.([...absentPending])
          exitAbsentMode()
        }}
        disabled={saving}
        className="text-xs font-bold px-4 py-1.5 rounded-lg bg-red-700 hover:bg-red-600 text-white transition-colors disabled:opacity-50 shrink-0"
      >
        {saving ? 'Saving…' : 'Confirm'}
      </button>
    </div>
  </div>
)}
```

- [ ] **Step 4: Exit absent mode when switching tabs**

The tab buttons already call `exitSwapMode()` on click. Add `exitAbsentMode()` to both:

```tsx
onClick={() => { setActiveTab('schedule'); exitSwapMode(); exitAbsentMode() }}
// and
onClick={() => { setActiveTab('standings'); exitSwapMode(); exitAbsentMode() }}
```

- [ ] **Step 5: Verify it compiles**

```bash
npm run build
```

Expected: no TypeScript errors.

- [ ] **Step 6: Manual test checklist**

Open the dev server (`npm run dev`), generate a schedule, publish it, open the shared session URL. Verify:

- [ ] "👤 Absent" button appears in toolbar on Schedule tab
- [ ] Clicking it enters absent mode: button becomes "✕ Cancel", player picker banner appears
- [ ] Swap button disappears while absent mode is active
- [ ] Tapping a player in picker selects them (red highlight), their chips in schedule show red strikethrough
- [ ] Tapping again deselects them
- [ ] Confirm bar appears as soon as a change is made
- [ ] Confirm bar text lists the selected players
- [ ] Confirming saves to cloud (optimistic update visible immediately)
- [ ] After confirm: absent chips remain red+strikethrough in schedule, absent mode exits
- [ ] Standings tab hides absent players
- [ ] Re-entering absent mode shows previously absent players pre-selected
- [ ] Deselecting all previously absent players and confirming removes all absent tags
- [ ] ✕ in confirm bar discards changes without saving
- [ ] "✕ Cancel" in toolbar discards changes without saving
- [ ] Swap mode still works normally when absent mode is not active
- [ ] Absent and Swap buttons cannot both be active simultaneously

- [ ] **Step 7: Commit**

```bash
git add src/components/SummaryModal.tsx
git commit -m "feat: absent mode UI — toolbar button, player picker, confirm bar"
```
