# Switch Slot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "↕ Switch slot" action to the Actions dropdown that lets users drag any game to swap its time slot/court with another game, with conflict detection preventing a player from appearing in two games in the same slot.

**Architecture:** Pure utility functions in `src/utils/slotSwap.ts` handle the swap logic and conflict detection. A `useSwapSlots` mutation in the queries layer persists the change. `SummaryModal` wraps the schedule in a `DndContext` when in switch-slot mode, rendering each game row as both draggable and droppable via a `SlotGameCard` sub-component. `SharedSessionPage` wires the mutation and passes `onSwapSlots` down.

**Tech Stack:** React 19, TypeScript, TanStack Query v5, Tailwind v4, `@dnd-kit/core` + `@dnd-kit/utilities` (new deps)

---

## File Map

| File | Change |
|------|--------|
| `src/utils/slotSwap.ts` | **Create** — `SlotSwapTarget`, `applySlotSwap`, `detectSlotSwapConflict` |
| `src/queries/sessions.ts` | **Modify** — add `useSwapSlots` mutation |
| `src/components/SummaryModal.tsx` | **Modify** — `SlotGameCard` component, state/helpers, dropdown item, DndContext, banner, confirm bar, guards |
| `src/pages/SharedSessionPage.tsx` | **Modify** — wire `useSwapSlots`, pass `onSwapSlots` |
| `package.json` / `package-lock.json` | **Modify** — `@dnd-kit/core`, `@dnd-kit/utilities` |

---

## Task 1: Create `src/utils/slotSwap.ts`

**Files:**
- Create: `src/utils/slotSwap.ts`

- [ ] **Step 1: Create the file**

```ts
import type { ScheduleSlot } from '../store'

export interface SlotSwapTarget {
  slot: number
  court: number
}

export function applySlotSwap(
  schedule: ScheduleSlot[],
  g1: SlotSwapTarget,
  g2: SlotSwapTarget,
): ScheduleSlot[] {
  return schedule.map((s) => {
    if (s.slot === g1.slot && s.court === g1.court) return { ...s, slot: g2.slot, court: g2.court }
    if (s.slot === g2.slot && s.court === g2.court) return { ...s, slot: g1.slot, court: g1.court }
    return s
  })
}

export function detectSlotSwapConflict(
  schedule: ScheduleSlot[],
  g1: SlotSwapTarget,
  g2: SlotSwapTarget,
): string | null {
  const game1 = schedule.find((s) => s.slot === g1.slot && s.court === g1.court)
  const game2 = schedule.find((s) => s.slot === g2.slot && s.court === g2.court)
  if (!game1 || !game2) return null

  const game1Players = [...game1.teamA, ...game1.teamB]
  const game2Players = [...game2.teamA, ...game2.teamB]

  // game1 moves to g2's slot — check others in that slot (excluding game2 itself)
  for (const other of schedule.filter((s) => s.slot === g2.slot && s.court !== g2.court)) {
    const otherPlayers = [...other.teamA, ...other.teamB]
    for (const pid of game1Players) {
      if (otherPlayers.includes(pid)) return pid
    }
  }

  // game2 moves to g1's slot — check others in that slot (excluding game1 itself)
  for (const other of schedule.filter((s) => s.slot === g1.slot && s.court !== g1.court)) {
    const otherPlayers = [...other.teamA, ...other.teamB]
    for (const pid of game2Players) {
      if (otherPlayers.includes(pid)) return pid
    }
  }

  return null
}
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/hidaydev/Code/badminton-pair && npm run build 2>&1 | tail -5
```

Expected: `✓ built in ...ms` with no errors.

- [ ] **Step 3: Commit**

```bash
git add src/utils/slotSwap.ts
git commit -m "feat: add applySlotSwap and detectSlotSwapConflict utilities"
```

---

## Task 2: Install `@dnd-kit` and add `useSwapSlots` mutation

**Files:**
- Modify: `package.json`
- Modify: `src/queries/sessions.ts`

- [ ] **Step 1: Install dnd-kit packages**

```bash
cd /Users/hidaydev/Code/badminton-pair && npm install @dnd-kit/core @dnd-kit/utilities
```

Expected: packages added to `node_modules` and `package-lock.json` updated.

- [ ] **Step 2: Add `useSwapSlots` to `src/queries/sessions.ts`**

First add the import at the top of the file alongside the existing `applySwap` import:

```ts
import { applySlotSwap, type SlotSwapTarget } from '../utils/slotSwap'
```

Then append the function at the end of the file (before `useFetchSession`):

```ts
export function useSwapSlots(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ g1, g2 }: { g1: SlotSwapTarget; g2: SlotSwapTarget }) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const nextSchedule = applySlotSwap(current.schedule, g1, g2)
      const updated: CloudSnapshot = { ...current, schedule: nextSchedule }
      await publishSession(sessionId, updated)
      return updated
    },
    onMutate: async ({ g1, g2 }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return { ...old, schedule: applySlotSwap(old.schedule, g1, g2) }
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['session', sessionId], context?.previous)
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
    },
  })
}
```

- [ ] **Step 3: Verify build**

```bash
npm run build 2>&1 | tail -5
```

Expected: `✓ built in ...ms` with no errors.

- [ ] **Step 4: Commit**

```bash
git add package.json package-lock.json src/queries/sessions.ts
git commit -m "feat: install @dnd-kit and add useSwapSlots mutation"
```

---

## Task 3: Add slot swap state, helpers, prop, and dropdown item to SummaryModal

**Files:**
- Modify: `src/components/SummaryModal.tsx`

- [ ] **Step 1: Add `SlotSwapTarget` import at the top of SummaryModal.tsx**

Find the existing import from `../utils/swap`:
```ts
import type { SwapTarget } from '../utils/swap'
```

Add alongside it:
```ts
import type { SlotSwapTarget } from '../utils/slotSwap'
import { detectSlotSwapConflict } from '../utils/slotSwap'
```

- [ ] **Step 2: Add `onSwapSlots` to the props interface and destructure it**

In the props interface (after `onReplacePlayer`):
```ts
onSwapSlots?: (g1: SlotSwapTarget, g2: SlotSwapTarget) => void
```

In the function destructuring (after `onReplacePlayer`):
```ts
onSwapSlots,
```

- [ ] **Step 3: Add slot swap state**

Near the other mode state declarations (`swapMode`, `absentMode`, `replaceMode`), add:

```ts
const [slotSwapMode, setSlotSwapMode] = useState(false)
const [pendingSlotSwap, setPendingSlotSwap] = useState<{ g1: SlotSwapTarget; g2: SlotSwapTarget } | null>(null)
const [slotSwapError, setSlotSwapError] = useState<string | null>(null)
```

- [ ] **Step 4: Add `exitSlotSwapMode` and `enterSlotSwapMode` helpers**

Add after the existing `enterReplaceMode` function:

```ts
function exitSlotSwapMode() {
  setSlotSwapMode(false)
  setPendingSlotSwap(null)
  setSlotSwapError(null)
}

function enterSlotSwapMode() {
  exitSwapMode()
  exitAbsentMode()
  exitReplaceMode()
  setActionsOpen(false)
  setSlotSwapMode(true)
}
```

- [ ] **Step 5: Thread `exitSlotSwapMode()` into all other mode-entry and tab-switch paths**

Update `enterAbsentMode`:
```ts
function enterAbsentMode() {
  exitSwapMode()
  exitReplaceMode()
  exitSlotSwapMode()
  setAbsentPending(new Set(absentPlayers))
  setAbsentMode(true)
}
```

Update `enterReplaceMode`:
```ts
function enterReplaceMode() {
  exitSwapMode()
  exitAbsentMode()
  exitSlotSwapMode()
  setReplaceMode(true)
}
```

Update both tab-switch `onClick` handlers:
```tsx
onClick={() => { setActiveTab('schedule'); exitSwapMode(); exitAbsentMode(); exitReplaceMode(); exitSlotSwapMode() }}
onClick={() => { setActiveTab('standings'); exitSwapMode(); exitAbsentMode(); exitReplaceMode(); exitSlotSwapMode() }}
```

Update the Cancel button `onClick`:
```tsx
onClick={() => { exitSwapMode(); exitAbsentMode(); exitReplaceMode(); exitSlotSwapMode(); setActionsOpen(false) }}
```

Update the Cancel button visibility condition from:
```tsx
swapMode || absentMode || replaceMode ? (
```
to:
```tsx
swapMode || absentMode || replaceMode || slotSwapMode ? (
```

- [ ] **Step 6: Add "↕ Switch slot" to the Actions dropdown**

After the Replace player item in the dropdown:
```tsx
{onSwapSlots && (
  <button
    onClick={() => { setActionsOpen(false); enterSlotSwapMode() }}
    className="w-full text-left px-4 py-2.5 text-xs font-medium text-orange-400 hover:bg-slate-800 transition-colors border-t border-slate-800"
  >
    ↕ Switch slot
  </button>
)}
```

- [ ] **Step 7: Verify build**

```bash
npm run build 2>&1 | tail -5
```

Expected: `✓ built` with no errors. (Some `noUnusedLocals` suppressions may be needed for `slotSwapMode`/`pendingSlotSwap`/`slotSwapError` until Task 4 uses them — see note below.)

Note: `noUnusedLocals: true` is set. If the build errors on the new state variables, prefix the `const [slotSwapMode, ...` lines with `// @ts-expect-error - used in Task 4` temporarily. These will be removed when Task 4 adds the DndContext JSX.

- [ ] **Step 8: Commit**

```bash
git add src/components/SummaryModal.tsx
git commit -m "feat: add slot swap state, helpers, and dropdown item to SummaryModal"
```

---

## Task 4: Add `SlotGameCard` component, DndContext, drag handles, and banner

**Files:**
- Modify: `src/components/SummaryModal.tsx`

- [ ] **Step 1: Add `@dnd-kit` imports at the top of SummaryModal.tsx**

Add after the existing React import:
```ts
import {
  DndContext,
  useDraggable,
  useDroppable,
  PointerSensor,
  TouchSensor,
  useSensor,
  useSensors,
  type DragEndEvent,
} from '@dnd-kit/core'
import { CSS } from '@dnd-kit/utilities'
```

- [ ] **Step 2: Add `SlotGameCard` sub-component**

Add this function **before** the `StandingsTab` function (i.e., near the top of the file, outside `SummaryModal`):

```tsx
function SlotGameCard({ id, children }: { id: string; children: React.ReactNode }) {
  const { attributes, listeners, setNodeRef: setDragRef, transform, isDragging } = useDraggable({ id })
  const { setNodeRef: setDropRef, isOver } = useDroppable({ id })

  return (
    <div
      ref={setDropRef}
      className={isOver && !isDragging ? 'outline outline-1 outline-orange-400/60 rounded-lg' : ''}
    >
      <div
        ref={setDragRef}
        style={transform ? { transform: CSS.Translate.toString(transform), position: 'relative', zIndex: 50 } : undefined}
        className={`flex items-center gap-2 ${isDragging ? 'opacity-40' : ''}`}
      >
        <span
          {...listeners}
          {...attributes}
          className="text-slate-500 hover:text-orange-400 cursor-grab active:cursor-grabbing text-base shrink-0 select-none touch-none px-0.5"
        >
          ⠿
        </span>
        {children}
      </div>
    </div>
  )
}
```

- [ ] **Step 3: Add `useSensors` and `handleDragEnd` inside `SummaryModal`**

Near the top of the `SummaryModal` function body, alongside the other state declarations, add:

```ts
const sensors = useSensors(
  useSensor(PointerSensor),
  useSensor(TouchSensor, { activationConstraint: { delay: 200, tolerance: 5 } }),
)

function handleDragEnd(event: DragEndEvent) {
  const { active, over } = event
  if (!over || active.id === over.id) return
  const parseId = (id: string | number) => {
    const [slot, court] = String(id).split('-').map(Number)
    return { slot, court }
  }
  const g1 = parseId(active.id)
  const g2 = parseId(over.id)
  const conflictId = detectSlotSwapConflict(result.schedule, g1, g2)
  if (conflictId) {
    setSlotSwapError(`Can't switch — ${playerMap.get(conflictId)?.name ?? conflictId} already plays in that slot`)
    return
  }
  setSlotSwapError(null)
  setPendingSlotSwap({ g1, g2 })
}
```

- [ ] **Step 4: Add the slot swap banner in the content area**

Find the existing `{absentMode && (` block and the `{replaceMode && (` block. Add the slot swap banner AFTER both:

```tsx
{slotSwapMode && (
  <div className="mb-3 rounded-lg bg-orange-950/30 border border-orange-900/40 px-3 py-2">
    {slotSwapError ? (
      <span className="text-xs text-red-400">{slotSwapError}</span>
    ) : (
      <span className="text-xs text-orange-300 font-medium">↕ Drag ⠿ to switch a game's slot</span>
    )}
  </div>
)}
```

- [ ] **Step 5: Wrap schedule content in DndContext and render `SlotGameCard` per game**

Find the schedule content section — specifically the outer `<div className="flex flex-col divide-y divide-slate-800">` that wraps the slot rows. Replace it with a conditional DndContext wrapper:

```tsx
{activeTab === 'standings' ? (
  <StandingsTab ... />
) : (
  (() => {
    const scheduleGrid = (
      <div className="flex flex-col divide-y divide-slate-800">
        {Array.from({ length: maxSlots }, (_, s) => {
          const games = (bySlot.get(s) ?? []).sort((a, b) => a.court - b.court)
          return (
            <div key={s} className="flex items-start gap-4 py-4">
              <div className="flex flex-col items-center w-4 shrink-0 pt-0.5 gap-0.5">
                <span className="text-xs font-bold text-slate-600">#{s + 1}</span>
                <span className="text-[8px] text-slate-700 font-medium leading-none">
                  {minutesToTime(timeToMinutes(sessionStart) + s * slotMinutes)}
                </span>
              </div>
              <div className="flex flex-col gap-2.5 flex-1">
                {games.map((g) => {
                  const key = `${s}-${g.court}`
                  const gameRow = (
                    /* PASTE THE EXISTING FULL GAME ROW JSX HERE — the <div key={g.court} className="flex flex-col gap-1"> block */
                    /* The only change inside: update the played checkbox and score toggle guards (Step 6) */
                  )
                  return slotSwapMode ? (
                    <SlotGameCard key={key} id={key}>
                      {gameRow}
                    </SlotGameCard>
                  ) : (
                    <div key={key}>{gameRow}</div>
                  )
                })}
              </div>
            </div>
          )
        })}
      </div>
    )
    return slotSwapMode ? (
      <DndContext sensors={sensors} onDragEnd={handleDragEnd}>
        {scheduleGrid}
      </DndContext>
    ) : scheduleGrid
  })()
)}
```

**Important:** The existing `key={g.court}` on the game row div must move to the outer wrapper (`SlotGameCard` or the plain `div`). Remove `key` from the inner game row div to avoid duplicate key warnings.

- [ ] **Step 6: Update played checkbox and score toggle guards for slotSwapMode**

The played checkbox `onClick` currently reads:
```tsx
onClick={() => { if (!saving && !swapMode && !replaceMode) onTogglePlayedGame(key) }}
```
Change to:
```tsx
onClick={() => { if (!saving && !swapMode && !replaceMode && !slotSwapMode) onTogglePlayedGame(key) }}
```

The played checkbox `className` condition:
```tsx
${swapMode || replaceMode ? 'cursor-not-allowed opacity-25' : ...}
```
Change to:
```tsx
${swapMode || replaceMode || slotSwapMode ? 'cursor-not-allowed opacity-25' : ...}
```

The score toggle:
```tsx
{!swapMode && !replaceMode && (savedScore && !isOpen ? (
```
Change to:
```tsx
{!swapMode && !replaceMode && !slotSwapMode && (savedScore && !isOpen ? (
```

- [ ] **Step 7: Remove any `@ts-expect-error` comments** added in Step 7 of Task 3 (if any were needed). The variables are now used in JSX.

- [ ] **Step 8: Update the bottom padding condition** for the confirm bar. Find:
```tsx
className={`... ${pendingSwap || absentChanged ? 'pb-24' : ''}`}
```
Change to:
```tsx
className={`... ${pendingSwap || absentChanged || pendingSlotSwap ? 'pb-24' : ''}`}
```

- [ ] **Step 9: Verify build**

```bash
npm run build 2>&1 | tail -5
```

Expected: `✓ built` with no errors.

- [ ] **Step 10: Commit**

```bash
git add src/components/SummaryModal.tsx
git commit -m "feat: add SlotGameCard, DndContext, drag handles, and slot swap banner"
```

---

## Task 5: Add slot swap confirm bar to SummaryModal

**Files:**
- Modify: `src/components/SummaryModal.tsx`

- [ ] **Step 1: Add the confirm bar**

Find the existing `{pendingSwap && (` confirm bar block (around the bottom of the component). Add the slot swap confirm bar AFTER it:

```tsx
{pendingSlotSwap && (
  <div className="fixed bottom-0 left-0 right-0 z-50 bg-slate-950 border-t border-orange-900/40 px-4 py-3">
    <div className="max-w-xl mx-auto">
      <div className="bg-orange-950/50 border border-orange-800/50 rounded-xl px-3 py-2.5 flex items-center gap-3">
        <div className="flex-1 min-w-0">
          <p className="text-xs font-semibold text-slate-200 truncate">
            <span className="text-orange-200">
              Slot {pendingSlotSwap.g1.slot + 1}{courtLabel(pendingSlotSwap.g1.court)}
            </span>
            {' ↕ '}
            <span className="text-orange-200">
              Slot {pendingSlotSwap.g2.slot + 1}{courtLabel(pendingSlotSwap.g2.court)}
            </span>
          </p>
          <p className="text-[10px] text-red-400 mt-0.5">⚠ Cannot be undone</p>
        </div>
        <button
          onClick={() => setPendingSlotSwap(null)}
          className="text-xs text-slate-500 hover:text-slate-300 px-2 py-1.5 rounded-lg border border-slate-700 bg-slate-800/60 transition-colors shrink-0"
        >
          ✕
        </button>
        <button
          onClick={() => { onSwapSlots?.(pendingSlotSwap.g1, pendingSlotSwap.g2); exitSlotSwapMode() }}
          disabled={saving}
          className="text-xs font-bold px-4 py-1.5 rounded-lg bg-orange-600 hover:bg-orange-500 text-white transition-colors disabled:opacity-50 shrink-0"
        >
          {saving ? 'Saving…' : 'Confirm'}
        </button>
      </div>
    </div>
  </div>
)}
```

- [ ] **Step 2: Verify build**

```bash
npm run build 2>&1 | tail -5
```

Expected: `✓ built` with no errors.

- [ ] **Step 3: Commit**

```bash
git add src/components/SummaryModal.tsx
git commit -m "feat: add slot swap confirm bar to SummaryModal"
```

---

## Task 6: Wire up in SharedSessionPage

**Files:**
- Modify: `src/pages/SharedSessionPage.tsx`

- [ ] **Step 1: Import `useSwapSlots` and `SlotSwapTarget`**

Find the existing import block:
```ts
import {
  useGetSession,
  useTogglePlayed,
  useSetScore,
  useSwapPlayers,
  useSetAbsent,
  useReplacePlayer,
  type CloudSnapshot,
} from '../queries'
```

Add `useSwapSlots`:
```ts
import {
  useGetSession,
  useTogglePlayed,
  useSetScore,
  useSwapPlayers,
  useSetAbsent,
  useReplacePlayer,
  useSwapSlots,
  type CloudSnapshot,
} from '../queries'
```

Also add the `SlotSwapTarget` type import:
```ts
import type { SlotSwapTarget } from '../utils/slotSwap'
```

- [ ] **Step 2: Instantiate the mutation**

After the `useReplacePlayer` line:
```ts
const { mutate: swapSlots, isPending: swapSlotsPending } = useSwapSlots(sessionId!)
```

- [ ] **Step 3: Add `swapSlotsPending` to `isSaving`**

```ts
const isSaving = togglePlayedPending || setScorePending || swapPlayersPending || setAbsentPending || replacePlayerPending || swapSlotsPending
```

- [ ] **Step 4: Pass `onSwapSlots` to `SummaryModal`**

After the `onReplacePlayer` prop:
```tsx
onSwapSlots={(g1: SlotSwapTarget, g2: SlotSwapTarget) => swapSlots({ g1, g2 }, {
  onSuccess: () => setSaveError(null),
  onError: () => setSaveError('Failed to save, please try again'),
})}
```

- [ ] **Step 5: Verify build**

```bash
npm run build 2>&1 | tail -5
```

Expected: `✓ built` with no errors.

- [ ] **Step 6: Start dev server and manually verify**

```bash
npm run dev
```

Open a shared session URL (`/s/:id`). Verify:
1. Actions dropdown now has "↕ Switch slot" as 4th item
2. Tapping it shows orange banner: "↕ Drag ⠿ to switch a game's slot"
3. Every game row shows a `⠿` drag handle on the left
4. On desktop: drag a game row and drop it onto another — confirm bar appears with slot labels
5. Confirm → both games trade slots, schedule reorders
6. Try dragging a game that would conflict — error message appears in banner instead of confirm bar
7. Cancel exits mode cleanly; tab switch exits mode cleanly

- [ ] **Step 7: Commit**

```bash
git add src/pages/SharedSessionPage.tsx
git commit -m "feat: wire useSwapSlots into SharedSessionPage"
```
