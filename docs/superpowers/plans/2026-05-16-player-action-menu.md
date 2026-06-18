# Player Action Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace two separate toolbar buttons (Absent, Swap) with a single "⋯ Actions" dropdown and add a third action — Replace player — that renames a player in the schedule by updating their name in `snapshot.players`.

**Architecture:** Four files touched. `useReplacePlayer` mutation added to the queries layer. `SummaryModal` gains a dropdown and replace mode UI (new state + banner + chip handlers). `SharedSessionPage` wires the mutation and passes the prop down.

**Tech Stack:** React 19, TypeScript, Zustand, TanStack Query v5, Tailwind v4

---

## File Map

| File | Change |
|------|--------|
| `src/queries/sessions.ts` | Add `useReplacePlayer` mutation |
| `src/queries/index.ts` | Export `useReplacePlayer` |
| `src/components/SummaryModal.tsx` | Dropdown, replace mode state + UI, updated chip rendering |
| `src/pages/SharedSessionPage.tsx` | Wire `useReplacePlayer`, pass `onReplacePlayer` |

---

## Task 1: Add `useReplacePlayer` mutation

**Files:**
- Modify: `src/queries/sessions.ts`
- Modify: `src/queries/index.ts`

- [ ] **Step 1: Add mutation to `src/queries/sessions.ts`**

Append this function at the end of the file, before the closing of any existing exports:

```ts
export function useReplacePlayer(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ playerId, newName }: { playerId: string; newName: string }) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const nextPlayers = current.players.map((p) =>
        p.id === playerId ? { ...p, name: newName } : p
      )
      const updated: CloudSnapshot = { ...current, players: nextPlayers }
      await publishSession(sessionId, updated)
      return updated
    },
    onMutate: async ({ playerId, newName }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return {
          ...old,
          players: old.players.map((p) => (p.id === playerId ? { ...p, name: newName } : p)),
        }
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

- [ ] **Step 2: Export from `src/queries/index.ts`**

Find the line that exports `useSetAbsent` and add `useReplacePlayer` alongside it:

```ts
export { useReplacePlayer } from './sessions'
```

- [ ] **Step 3: Verify TypeScript compiles**

```bash
npm run build 2>&1 | head -30
```

Expected: no errors mentioning `useReplacePlayer`.

- [ ] **Step 4: Commit**

```bash
git add src/queries/sessions.ts src/queries/index.ts
git commit -m "feat: add useReplacePlayer mutation"
```

---

## Task 2: Add dropdown and replace mode state to SummaryModal

**Files:**
- Modify: `src/components/SummaryModal.tsx`

- [ ] **Step 1: Add `onReplacePlayer` to the props interface**

Find the props interface (around line 153). Add after `onSetAbsent`:

```ts
onReplacePlayer?: (playerId: string, newName: string) => void
```

And destructure it in the function signature after `onSetAbsent`:

```ts
onReplacePlayer,
```

- [ ] **Step 2: Add replace mode state**

Find the existing state declarations (around line 183, near `swapMode`, `absentMode`). Add these after `absentMode`:

```ts
const [replaceMode, setReplaceMode] = useState(false)
const [replaceTarget, setReplaceTarget] = useState<string | null>(null)
const [replaceName, setReplaceName] = useState('')
```

- [ ] **Step 3: Add `exitReplaceMode` and `enterReplaceMode` functions**

Add these after the existing `exitAbsentMode` function:

```ts
function exitReplaceMode() {
  setReplaceMode(false)
  setReplaceTarget(null)
  setReplaceName('')
}

function enterReplaceMode() {
  exitSwapMode()
  exitAbsentMode()
  setReplaceMode(true)
}
```

- [ ] **Step 4: Update `enterAbsentMode` to also exit replace mode**

Find `enterAbsentMode` (around line 191). Change:

```ts
function enterAbsentMode() {
  exitSwapMode()
  setAbsentPending(new Set(absentPlayers))
  setAbsentMode(true)
}
```

To:

```ts
function enterAbsentMode() {
  exitSwapMode()
  exitReplaceMode()
  setAbsentPending(new Set(absentPlayers))
  setAbsentMode(true)
}
```

- [ ] **Step 5: Add `actionsOpen` state for the dropdown**

Add with the other state declarations:

```ts
const [actionsOpen, setActionsOpen] = useState(false)
```

- [ ] **Step 6: Add `exitReplaceMode()` to tab-switch handlers**

Find the two tab buttons (Schedule and Leaderboard, around line 311). Update their `onClick` handlers to also call `exitReplaceMode()`:

```tsx
onClick={() => { setActiveTab('schedule'); exitSwapMode(); exitAbsentMode(); exitReplaceMode() }}
```

```tsx
onClick={() => { setActiveTab('standings'); exitSwapMode(); exitAbsentMode(); exitReplaceMode() }}
```

- [ ] **Step 7: Commit**

```bash
git add src/components/SummaryModal.tsx
git commit -m "feat: add replace mode state and helpers to SummaryModal"
```

---

## Task 3: Replace toolbar buttons with Actions dropdown

**Files:**
- Modify: `src/components/SummaryModal.tsx`

- [ ] **Step 1: Replace the right side of the toolbar**

Find the `<div className="flex items-center gap-2">` on the right side of the toolbar (around line 329). It currently contains conditional absent button, conditional swap button, and optional close button. Replace the absent + swap buttons with the new dropdown + cancel logic:

```tsx
<div className="flex items-center gap-2">
  {activeTab === 'schedule' && (onSwapPlayers || onSetAbsent || onReplacePlayer) && (
    swapMode || absentMode || replaceMode ? (
      <button
        onClick={() => { exitSwapMode(); exitAbsentMode(); exitReplaceMode() }}
        className="text-xs font-semibold px-3 py-1.5 rounded-lg bg-slate-800 border border-slate-600 text-slate-300 hover:text-white transition-colors"
      >
        ✕<span className="hidden sm:inline"> Cancel</span>
      </button>
    ) : (
      <div className="relative">
        <button
          onClick={() => setActionsOpen((v) => !v)}
          className="text-xs font-semibold px-3 py-1.5 rounded-lg bg-slate-800/60 border border-slate-700 text-slate-300 hover:text-white transition-colors"
        >
          ⋯<span className="hidden sm:inline"> Actions</span>
        </button>
        {actionsOpen && (
          <>
            <div className="fixed inset-0 z-10" onClick={() => setActionsOpen(false)} />
            <div className="absolute right-0 top-full mt-1 z-20 bg-slate-900 border border-slate-700 rounded-xl shadow-xl min-w-[160px] overflow-hidden">
              {onSwapPlayers && (
                <button
                  onClick={() => { setActionsOpen(false); setSwapMode(true) }}
                  className="w-full text-left px-4 py-2.5 text-xs font-medium text-indigo-300 hover:bg-slate-800 transition-colors"
                >
                  ⇄ Swap players
                </button>
              )}
              {onSetAbsent && (
                <button
                  onClick={() => { setActionsOpen(false); enterAbsentMode() }}
                  className="w-full text-left px-4 py-2.5 text-xs font-medium text-red-400 hover:bg-slate-800 transition-colors border-t border-slate-800"
                >
                  👤 Mark absent
                </button>
              )}
              {onReplacePlayer && (
                <button
                  onClick={() => { setActionsOpen(false); enterReplaceMode() }}
                  className="w-full text-left px-4 py-2.5 text-xs font-medium text-emerald-400 hover:bg-slate-800 transition-colors border-t border-slate-800"
                >
                  ↔ Replace player
                </button>
              )}
            </div>
          </>
        )}
      </div>
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
```

- [ ] **Step 2: Verify build**

```bash
npm run build 2>&1 | head -30
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add src/components/SummaryModal.tsx
git commit -m "feat: replace absent/swap buttons with Actions dropdown"
```

---

## Task 4: Add replace mode banner and chip interaction

**Files:**
- Modify: `src/components/SummaryModal.tsx`

- [ ] **Step 1: Add replace mode banner to the content area**

Find the `{absentMode && (` block (around line 409). Add the replace mode banner immediately after the closing `)}` of the absent mode block:

```tsx
{replaceMode && (
  <div className="mb-3 rounded-lg bg-emerald-950/30 border border-emerald-900/40 px-3 py-2 flex flex-col gap-2">
    {replaceTarget === null ? (
      <span className="text-xs text-emerald-300 font-medium">Tap a player to replace</span>
    ) : (
      <>
        <span className="text-xs text-emerald-300 font-medium">
          Replace <strong>{playerMap.get(replaceTarget)?.name}</strong> with:
        </span>
        <div className="flex gap-2 items-center">
          <input
            type="text"
            value={replaceName}
            onChange={(e) => setReplaceName(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && replaceName.trim()) {
                onReplacePlayer?.(replaceTarget, replaceName.trim())
                exitReplaceMode()
              }
            }}
            placeholder="New name…"
            autoFocus
            className="flex-1 bg-slate-900 border border-emerald-800 rounded-lg px-3 py-1.5 text-xs text-white placeholder:text-slate-600 focus:outline-none focus:border-emerald-500"
          />
          <button
            onClick={() => {
              if (!replaceName.trim()) return
              onReplacePlayer?.(replaceTarget, replaceName.trim())
              exitReplaceMode()
            }}
            disabled={!replaceName.trim() || saving}
            className="text-xs font-bold px-3 py-1.5 rounded-lg bg-emerald-700 hover:bg-emerald-600 text-white transition-colors disabled:opacity-50 disabled:cursor-not-allowed shrink-0"
          >
            {saving ? 'Saving…' : '✓ Save'}
          </button>
        </div>
      </>
    )}
  </div>
)}
```

- [ ] **Step 2: Update player chip rendering for replace mode**

The chips are rendered twice — once for `teamA` and once for `teamB`. Both blocks have the same structure. For each, find the innermost ternary that decides the chip appearance. It currently has three branches:

```tsx
swapMode && !done && !pendingSwap ? (/* swap button */)
: swapMode && !done && pendingSwap ? (/* dimmed swap span */)
: (/* plain span */)
```

Add replace mode as the first branch in each block:

```tsx
replaceMode && !done ? (
  <button
    onClick={() => {
      if (replaceTarget === id) {
        setReplaceTarget(null)
        setReplaceName('')
      } else {
        setReplaceTarget(id)
        setReplaceName('')
      }
    }}
    className={`text-xs font-medium px-1.5 py-0.5 rounded-md border transition-colors ${
      replaceTarget === id
        ? 'bg-emerald-900/50 border-emerald-500 text-emerald-200 ring-1 ring-emerald-500/60'
        : 'bg-slate-800/60 border-slate-600 text-slate-200 hover:border-emerald-400 hover:text-emerald-200'
    }`}
  >
    {n}
  </button>
) : swapMode && !done && !pendingSwap ? (
  /* existing swap button — unchanged */
) : swapMode && !done && pendingSwap ? (
  /* existing dimmed swap span — unchanged */
) : (
  /* existing plain span — unchanged */
)
```

Apply this change to **both** the `teamA` chip block and the `teamB` chip block (they are identical in structure, search for `target: SwapTarget = { slot: s, court: g.court, playerId: id, team: 'A'` and `team: 'B'`).

- [ ] **Step 3: Verify build**

```bash
npm run build 2>&1 | head -30
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add src/components/SummaryModal.tsx
git commit -m "feat: add replace player banner and chip interaction to SummaryModal"
```

---

## Task 5: Wire up in SharedSessionPage

**Files:**
- Modify: `src/pages/SharedSessionPage.tsx`

- [ ] **Step 1: Import and instantiate `useReplacePlayer`**

Find the existing mutation imports at the top of the file:

```ts
import {
  useGetSession,
  useTogglePlayed,
  useSetScore,
  useSwapPlayers,
  useSetAbsent,
  type CloudSnapshot,
} from '../queries'
```

Add `useReplacePlayer` to the import list:

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

Then find where the other mutations are instantiated (around line 22):

```ts
const { mutate: setAbsent, isPending: setAbsentPending } = useSetAbsent(sessionId!)
```

Add below it:

```ts
const { mutate: replacePlayer, isPending: replacePlayerPending } = useReplacePlayer(sessionId!)
```

- [ ] **Step 2: Add `replacePlayerPending` to the `isSaving` flag**

Find:

```ts
const isSaving = togglePlayedPending || setScorePending || swapPlayersPending || setAbsentPending
```

Change to:

```ts
const isSaving = togglePlayedPending || setScorePending || swapPlayersPending || setAbsentPending || replacePlayerPending
```

- [ ] **Step 3: Pass `onReplacePlayer` to `SummaryModal`**

Find the `<SummaryModal` usage. Add the prop after `onSetAbsent`:

```tsx
onReplacePlayer={(playerId, newName) => replacePlayer({ playerId, newName }, {
  onSuccess: () => setSaveError(null),
  onError: () => setSaveError('Failed to save, please try again'),
})}
```

- [ ] **Step 4: Verify build**

```bash
npm run build 2>&1 | head -30
```

Expected: clean build, no TypeScript errors.

- [ ] **Step 5: Start dev server and manually verify**

```bash
npm run dev
```

Open a shared session URL (`/s/:id`). Verify:
1. Toolbar shows "⋯ Actions" button instead of two separate buttons
2. Tapping Actions opens dropdown with Swap players / Mark absent / Replace player
3. Tapping outside the dropdown closes it
4. Selecting Swap → enters swap mode, Cancel exits
5. Selecting Absent → enters absent mode, Cancel exits
6. Selecting Replace → green banner appears: "Tap a player to replace"
7. Tapping a player chip → input appears with player's name shown, type a new name → Save
8. Player name updates immediately in the schedule (optimistic update)
9. Refresh — new name persists

- [ ] **Step 6: Commit**

```bash
git add src/pages/SharedSessionPage.tsx
git commit -m "feat: wire useReplacePlayer into SharedSessionPage"
```
