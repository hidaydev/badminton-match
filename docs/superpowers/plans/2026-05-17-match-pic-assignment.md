# Match PIC Assignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** For each group-stage match, automatically assign one person from the group as the scoring PIC (Person In Charge); the PIC cannot be playing in that match and each person is PIC at most once per group.

**Architecture:** Pure `assignGroupPics` function added to `src/utils/tournament.ts` is called inside `useConfirmGroups` after generating matches and inside a new `useRegeneratePics` mutation; `picName` is stored on `TournamentMatch` and displayed below the score badge in `GroupMatches.tsx`.

**Tech Stack:** TypeScript, React 19, TanStack Query v5, Tailwind v4

---

## File Map

| File | Change |
|------|--------|
| `src/utils/tournament.ts` | Add `picName?: string \| null` to `TournamentMatch`; export `assignGroupPics` |
| `src/queries/tournament.ts` | Call `assignGroupPics` in `useConfirmGroups`; add `useRegeneratePics` |
| `src/components/tournament/GroupMatches.tsx` | Render `picName`; add "Regenerate PICs" button + `onRegeneratePics` prop |
| `src/pages/TournamentPage.tsx` | Use `useRegeneratePics`; wire `onRegeneratePics` into `GroupMatches` |

---

### Task 1: Add `picName` to `TournamentMatch` and implement `assignGroupPics`

**Files:**
- Modify: `src/utils/tournament.ts`

- [ ] **Step 1: Add `picName` field to `TournamentMatch`**

In `src/utils/tournament.ts`, update the `TournamentMatch` interface (lines 9–17):

```ts
export interface TournamentMatch {
  id: string
  phase: MatchPhase
  groupId?: GroupId
  pairAId: string | null
  pairBId: string | null
  scoreA: number | null
  scoreB: number | null
  picName?: string | null
}
```

- [ ] **Step 2: Add `assignGroupPics` function**

Append to the bottom of `src/utils/tournament.ts`:

```ts
export function assignGroupPics(
  pairs: TournamentPair[],
  groups: Record<GroupId, string[]>,
  matches: TournamentMatch[]
): TournamentMatch[] {
  const pairNameMap = new Map(pairs.map((p) => [p.id, p.name]))

  const result = matches.map((m) => ({ ...m }))

  for (const g of ['A', 'B', 'C', 'D'] as GroupId[]) {
    // Build pairId -> individual names
    const pairNames = new Map<string, string[]>()
    for (const pairId of groups[g]) {
      const name = pairNameMap.get(pairId) ?? pairId
      pairNames.set(pairId, name.includes(' & ') ? name.split(' & ') : [name])
    }

    // Pool of all 8 names in the group, shuffled
    const pool: string[] = []
    for (const names of pairNames.values()) pool.push(...names)
    for (let i = pool.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [pool[i], pool[j]] = [pool[j], pool[i]]
    }

    const used = new Set<string>()
    const groupMatches = result.filter((m) => m.phase === 'group' && m.groupId === g)

    for (const m of groupMatches) {
      const playing = new Set<string>([
        ...(m.pairAId ? (pairNames.get(m.pairAId) ?? []) : []),
        ...(m.pairBId ? (pairNames.get(m.pairBId) ?? []) : []),
      ])
      const pic = pool.find((name) => !playing.has(name) && !used.has(name))
      if (pic) {
        m.picName = pic
        used.add(pic)
      }
    }
  }

  return result
}
```

- [ ] **Step 3: Verify TypeScript compiles**

```bash
npm run build
```

Expected: no type errors. `assignGroupPics` is now exported.

- [ ] **Step 4: Commit**

```bash
git add src/utils/tournament.ts
git commit -m "feat: add picName to TournamentMatch and implement assignGroupPics"
```

---

### Task 2: Wire `assignGroupPics` into queries and add `useRegeneratePics`

**Files:**
- Modify: `src/queries/tournament.ts`

- [ ] **Step 1: Import `assignGroupPics` in `src/queries/tournament.ts`**

Update the import from `'../utils/tournament'` (lines 5–9):

```ts
import {
  generateGroupMatches,
  initKnockoutMatches,
  propagateBracket,
  assignGroupPics,
} from '../utils/tournament'
```

- [ ] **Step 2: Call `assignGroupPics` inside `useConfirmGroups`**

In `useConfirmGroups` `mutationFn` (currently lines 36–39), update to:

```ts
const groupMatches = GROUP_IDS.flatMap((g) => generateGroupMatches(g, localGroups[g]))
const allMatches = [...groupMatches, ...initKnockoutMatches()]
const propagated = propagateBracket(allMatches, localGroups, pairs)
const newMatches = assignGroupPics(pairs, localGroups, propagated)
await publishTournament(TOURNAMENT_ID, { name, date, pairs, groups: localGroups, matches: newMatches })
```

- [ ] **Step 3: Add `useRegeneratePics` mutation**

Append to `src/queries/tournament.ts` after `useResetTournament`:

```ts
export function useRegeneratePics() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async () => {
      const current = queryClient.getQueryData<TournamentSnapshot | null>(['tournament', TOURNAMENT_ID])
      if (!current) throw new Error('no tournament data')
      const newMatches = assignGroupPics(current.pairs, current.groups, current.matches)
      const next = { ...current, matches: newMatches }
      await publishTournament(TOURNAMENT_ID, next)
      return next
    },
    onMutate: async () => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
  })
}
```

- [ ] **Step 4: Verify TypeScript compiles**

```bash
npm run build
```

Expected: no type errors.

- [ ] **Step 5: Commit**

```bash
git add src/queries/tournament.ts
git commit -m "feat: wire assignGroupPics into useConfirmGroups and add useRegeneratePics"
```

---

### Task 3: Display `picName` and "Regenerate PICs" button in `GroupMatches`

**Files:**
- Modify: `src/components/tournament/GroupMatches.tsx`

- [ ] **Step 1: Add `onRegeneratePics` prop to `Props` interface**

Update the `Props` interface (lines 8–17):

```ts
interface Props {
  pairs: TournamentPair[]
  groups: Record<GroupId, string[]>
  matches: TournamentMatch[]
  onSetMatchScore: (matchId: string, scoreA: number, scoreB: number) => void
  onResetGroups: () => void
  onRegeneratePics: () => void
  isRegeneratingPics: boolean
  onOpenModal: () => void
  isFetching: boolean
  refetch: () => Promise<unknown>
}
```

- [ ] **Step 2: Destructure `onRegeneratePics` and `isRegeneratingPics` in the component signature**

Update the function signature (line 19):

```ts
export default function GroupMatches({ pairs, groups, matches, onSetMatchScore, onResetGroups, onRegeneratePics, isRegeneratingPics, onOpenModal, isFetching, refetch }: Props) {
```

- [ ] **Step 3: Add "Regenerate PICs" button next to "Reset groups"**

Replace the existing `<div className="flex justify-end">` block (lines 28–37) with:

```tsx
<div className="flex justify-end gap-3">
  <button
    onClick={onRegeneratePics}
    disabled={isRegeneratingPics}
    className="text-xs text-slate-500 hover:text-slate-300 underline disabled:opacity-50"
  >
    {isRegeneratingPics ? 'Regenerating…' : 'Regenerate PICs'}
  </button>
  <button
    onClick={() => {
      if (confirm('Reset group assignment? All scores will be lost.')) onResetGroups()
    }}
    className="text-xs text-slate-500 hover:text-slate-300 underline"
  >
    Reset groups
  </button>
</div>
```

- [ ] **Step 4: Replace score badge span with flex column showing score + picName**

Replace the `<span>` for the score badge inside the match row button (line 60):

```tsx
<div className="shrink-0 min-w-[56px] flex flex-col items-center">
  <span className="text-xs font-bold text-yellow-400 bg-slate-900 rounded-md px-2 py-1">
    {m.scoreA !== null ? `${m.scoreA}–${m.scoreB}` : '—'}
  </span>
  {m.picName && (
    <span className="text-[9px] text-slate-500 mt-0.5 leading-none">{m.picName}</span>
  )}
</div>
```

- [ ] **Step 5: Verify TypeScript compiles**

```bash
npm run build
```

Expected: type error in `TournamentPage.tsx` because `onRegeneratePics` and `isRegeneratingPics` are not yet passed — that is expected and will be fixed in Task 4.

- [ ] **Step 6: Commit**

```bash
git add src/components/tournament/GroupMatches.tsx
git commit -m "feat: display picName below score badge and add Regenerate PICs button"
```

---

### Task 4: Wire `useRegeneratePics` into `TournamentPage`

**Files:**
- Modify: `src/pages/TournamentPage.tsx`

- [ ] **Step 1: Import `useRegeneratePics` in `TournamentPage.tsx`**

Update the import from `'../queries'` (lines 3–9):

```ts
import {
  useGetTournament,
  useConfirmGroups,
  useSetTournamentScore,
  useResetTournament,
  useRegeneratePics,
  TOURNAMENT_ID,
} from '../queries'
```

- [ ] **Step 2: Destructure `useRegeneratePics` mutation**

After the existing mutation destructures (around line 105–109), add:

```ts
const { mutate: regeneratePics, isPending: regeneratePicsPending } = useRegeneratePics()
```

Also update `isSaving` to include `regeneratePicsPending`:

```ts
const isSaving = confirmPending || setScorePending || resetPending || regeneratePicsPending
```

- [ ] **Step 3: Pass `onRegeneratePics` and `isRegeneratingPics` to `GroupMatches`**

Update the `<GroupMatches ... />` JSX (lines 174–192) to include:

```tsx
<GroupMatches
  pairs={pairs}
  groups={committedGroups}
  matches={matches}
  onSetMatchScore={(id, a, b) => setTournamentScore({ matchId: id, scoreA: a, scoreB: b }, {
    onSuccess: () => setSaveError(null),
    onError: () => setSaveError('Failed to save score, please try again'),
  })}
  onResetGroups={() => resetTournament({ name, date, pairs }, {
    onSuccess: () => {
      setSaveError(null)
      setLocalGroups(EMPTY_GROUPS)
    },
    onError: () => setSaveError('Failed to reset, please try again'),
  })}
  onRegeneratePics={() => regeneratePics(undefined, {
    onSuccess: () => setSaveError(null),
    onError: () => setSaveError('Failed to regenerate PICs, please try again'),
  })}
  isRegeneratingPics={regeneratePicsPending}
  onOpenModal={handleOpenModal}
  isFetching={isFetching}
  refetch={refetch}
/>
```

- [ ] **Step 4: Verify full build passes**

```bash
npm run build
```

Expected: clean build, no type errors.

- [ ] **Step 5: Commit**

```bash
git add src/pages/TournamentPage.tsx
git commit -m "feat: wire useRegeneratePics into TournamentPage"
```

---

## Self-Review

**Spec coverage:**
- ✅ `picName?: string | null` added to `TournamentMatch`
- ✅ `assignGroupPics` pure function splits names by ` & `, shuffles, greedy walk per match
- ✅ Called in `useConfirmGroups` after `propagateBracket`, before `publishTournament`
- ✅ `useRegeneratePics` mutation reads current snapshot, reassigns, publishes
- ✅ `picName` rendered below score badge in `GroupMatches`
- ✅ "Regenerate PICs" button with disabled state while pending
- ✅ Exported from `src/queries/index.ts` via `export * from './tournament'` (no change needed — wildcard already covers it)

**Placeholder scan:** None found.

**Type consistency:** `assignGroupPics` signature and call sites match throughout. `onRegeneratePics: () => void` and `isRegeneratingPics: boolean` match between Props and TournamentPage usage. `useRegeneratePics` takes no variables — `mutate(undefined, ...)` is correct for TanStack Query v5 with no variables.
