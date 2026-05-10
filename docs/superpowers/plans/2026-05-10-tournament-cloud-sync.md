# Tournament Cloud Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate the tournament feature with Google Sheets via the existing Apps Script backend — group assignment stays localStorage, match scores auto-save to cloud via React Query mutations.

**Architecture:** The Zustand tournament store keeps `persist` for group assignment state. Once groups are locked, `TournamentPage` becomes the cloud sync orchestrator: `useQuery` hydrates match scores from cloud on mount, `useMutation` publishes after every `setMatchScore` or `resetGroups` and invalidates the query. Components receive score mutation callbacks as props instead of calling the store directly.

**Tech Stack:** React 19, Zustand (persist), @tanstack/react-query v5, Google Apps Script (existing endpoint via `VITE_APPS_SCRIPT_URL`)

---

## File Map

| File | Change |
|------|--------|
| `src/utils/cloudSync.ts` | Add `TOURNAMENT_ID`, `TournamentSnapshot` type, `getTournament`, `publishTournament` |
| `src/store/tournament.ts` | Add `hydrateFromCloud` action for hydrating matches from cloud; keep `persist` |
| `src/pages/TournamentPage.tsx` | Add `useQuery` + two `useMutation`s; pass callbacks to children |
| `src/components/tournament/GroupMatches.tsx` | Accept `onSetMatchScore` + `onResetGroups` props |
| `src/components/tournament/BracketTab.tsx` | Accept `onSetMatchScore` prop |
| **Google Apps Script** | Add `getTournament` GET handler + tournament POST handler in existing script |

---

## Task 1: Add `getTournament` and `publishTournament` to `cloudSync.ts`

**Files:**
- Modify: `src/utils/cloudSync.ts`

- [ ] **Step 1: Add types and functions**

Open `src/utils/cloudSync.ts` and append after the last export:

```ts
import type { GroupId, TournamentMatch, TournamentPair } from '../store/tournament'

export const TOURNAMENT_ID = 'tournament-2026-05-23-majadu'

export interface TournamentSnapshot {
  name: string
  date: string
  pairs: TournamentPair[]
  groups: Record<GroupId, string[]>
  groupsLocked: boolean
  matches: TournamentMatch[]
}

export async function getTournament(id: string): Promise<TournamentSnapshot | null> {
  const res = await fetch(`${scriptUrl()}?action=getTournament&id=${encodeURIComponent(id)}`)
  const json = await res.json() as { ok: boolean; data?: TournamentSnapshot; error?: string }
  if (!json.ok) return null
  return json.data ?? null
}

export async function publishTournament(id: string, data: TournamentSnapshot): Promise<void> {
  const res = await fetch(scriptUrl(), {
    method: 'POST',
    body: JSON.stringify({ type: 'tournament', id, data }),
  })
  const json = await res.json() as { ok: boolean; error?: string }
  if (!json.ok) throw new Error(json.error ?? 'publish tournament failed')
}
```

- [ ] **Step 2: Verify TypeScript compiles**

```bash
npm run build 2>&1 | head -30
```

Expected: no type errors related to `cloudSync.ts`.

- [ ] **Step 3: Commit**

```bash
git add src/utils/cloudSync.ts
git commit -m "feat: add getTournament and publishTournament to cloudSync"
```

---

## Task 2: Add `partialSet` action to tournament store

**Files:**
- Modify: `src/store/tournament.ts`

The store needs a way for `TournamentPage` to hydrate `matches` from cloud without triggering a full store reset. Add a `hydratFromCloud` action.

- [ ] **Step 1: Add `hydrateFromCloud` to the store interface and implementation**

In `src/store/tournament.ts`, add to the `TournamentState` interface:

```ts
hydrateFromCloud: (matches: TournamentMatch[]) => void
```

Add the implementation inside `create`:

```ts
hydrateFromCloud: (matches) => set({ matches }),
```

- [ ] **Step 2: Verify TypeScript compiles**

```bash
npm run build 2>&1 | head -30
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add src/store/tournament.ts
git commit -m "feat: add hydrateFromCloud action to tournament store"
```

---

## Task 3: Update Google Apps Script

**Files:**
- Google Apps Script (cloud — you must edit this in the Apps Script editor)

The existing script handles session GET/POST. Add two new branches.

- [ ] **Step 1: Add `Tournament` sheet and GET handler**

In the Apps Script `doGet(e)` function, add this branch alongside the existing `action` checks:

```js
if (e.parameter.action === 'getTournament') {
  const id = e.parameter.id
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName('Tournament')
  if (!sheet) return jsonResponse({ ok: false, error: 'Tournament sheet not found' })
  const data = sheet.getDataRange().getValues()
  for (let i = 1; i < data.length; i++) {
    if (data[i][0] === id) {
      return jsonResponse({ ok: true, data: JSON.parse(data[i][3]) })
    }
  }
  return jsonResponse({ ok: false, error: 'not found' })
}
```

- [ ] **Step 2: Add POST handler for tournament**

In the Apps Script `doPost(e)` function, add this branch:

```js
const body = JSON.parse(e.postData.contents)
if (body.type === 'tournament') {
  const { id, data } = body
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName('Tournament')
  if (!sheet) {
    // Create the sheet if it doesn't exist
    SpreadsheetApp.getActiveSpreadsheet().insertSheet('Tournament')
    const newSheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName('Tournament')
    newSheet.appendRow(['id', 'name', 'date', 'data']) // header
  }
  const tSheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName('Tournament')
  const rows = tSheet.getDataRange().getValues()
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][0] === id) {
      tSheet.getRange(i + 1, 4).setValue(JSON.stringify(data))
      return jsonResponse({ ok: true })
    }
  }
  tSheet.appendRow([id, data.name, data.date, JSON.stringify(data)])
  return jsonResponse({ ok: true })
}
```

- [ ] **Step 3: Deploy new version**

In the Apps Script editor: **Deploy → Manage deployments → New version → Deploy**.

- [ ] **Step 4: Verify GET endpoint manually**

```bash
curl "YOUR_APPS_SCRIPT_URL?action=getTournament&id=tournament-2026-05-23-majadu"
```

Expected: `{"ok":false,"error":"not found"}` (no data yet — that's correct).

---

## Task 4: Wire `useQuery` and `useMutation` in `TournamentPage`

**Files:**
- Modify: `src/pages/TournamentPage.tsx`

- [ ] **Step 1: Add imports**

At the top of `src/pages/TournamentPage.tsx`, add:

```ts
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  getTournament,
  publishTournament,
  TOURNAMENT_ID,
  type TournamentSnapshot,
} from '../utils/cloudSync'
import { useTournamentStore } from '../store/tournament'
```

- [ ] **Step 2: Add query + hydration inside the component**

Inside `TournamentPage`, after the existing store selectors, add:

```ts
const queryClient = useQueryClient()
const hydrateFromCloud = useTournamentStore((s) => s.hydrateFromCloud)

const [saveError, setSaveError] = useState<string | null>(null)

const { data: cloudSnapshot } = useQuery<TournamentSnapshot | null>({
  queryKey: ['tournament', TOURNAMENT_ID],
  queryFn: () => getTournament(TOURNAMENT_ID),
  enabled: groupsLocked,
})

useEffect(() => {
  if (cloudSnapshot?.matches) {
    hydrateFromCloud(cloudSnapshot.matches)
  }
}, [cloudSnapshot, hydrateFromCloud])
```

Also add `useEffect` to the existing React import at the top of the file:
```ts
import { useState, useEffect } from 'react'
```

- [ ] **Step 3: Add `handleSetMatchScore` mutation**

```ts
const setMatchScore = useTournamentStore((s) => s.setMatchScore)

const setScoreMutation = useMutation({
  mutationFn: async ({ matchId, scoreA, scoreB }: { matchId: string; scoreA: number; scoreB: number }) => {
    setMatchScore(matchId, scoreA, scoreB)
    const state = useTournamentStore.getState()
    const snapshot: TournamentSnapshot = {
      name: state.name,
      date: state.date,
      pairs: state.pairs,
      groups: state.groups,
      groupsLocked: state.groupsLocked,
      matches: state.matches,
    }
    await publishTournament(TOURNAMENT_ID, snapshot)
  },
  onSuccess: () => setSaveError(null),
  onError: () => setSaveError('Failed to save score, please try again'),
  onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
})

const handleSetMatchScore = (matchId: string, scoreA: number, scoreB: number) => {
  setScoreMutation.mutate({ matchId, scoreA, scoreB })
}
```

- [ ] **Step 4: Add `handleResetGroups` mutation**

```ts
const resetGroups = useTournamentStore((s) => s.resetGroups)

const resetMutation = useMutation({
  mutationFn: async () => {
    resetGroups()
    // After reset, publish the cleared state
    const state = useTournamentStore.getState()
    const snapshot: TournamentSnapshot = {
      name: state.name,
      date: state.date,
      pairs: state.pairs,
      groups: state.groups,
      groupsLocked: state.groupsLocked,
      matches: state.matches,
    }
    await publishTournament(TOURNAMENT_ID, snapshot)
  },
  onSuccess: () => setSaveError(null),
  onError: () => setSaveError('Failed to reset, please try again'),
  onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
})

const handleResetGroups = () => resetMutation.mutate()
```

- [ ] **Step 5: Derive `isSaving` and add saving indicator to header**

```ts
const isSaving = setScoreMutation.isPending || resetMutation.isPending
```

In the header JSX, after the date line, add:

```tsx
{groupsLocked && (
  <span className="text-[10px] text-slate-500 ml-auto">
    {isSaving ? 'Saving…' : 'Saved'}
  </span>
)}
```

Also add the error toast just inside the outer `<div>`:

```tsx
{saveError && (
  <div className="fixed top-4 left-1/2 -translate-x-1/2 z-[60] bg-red-900/90 border border-red-700 text-red-200 text-xs px-4 py-2 rounded-lg">
    {saveError}
  </div>
)}
```

- [ ] **Step 6: Pass callbacks to tab components**

Update the tab content section:

```tsx
{tab === 'groups' && (
  groupsLocked
    ? <GroupMatches onSetMatchScore={handleSetMatchScore} onResetGroups={handleResetGroups} />
    : <GroupAssignment />
)}
{tab === 'bracket' && <BracketTab onSetMatchScore={handleSetMatchScore} />}
{tab === 'standings' && <StandingsTab />}
```

- [ ] **Step 7: Verify TypeScript compiles**

```bash
npm run build 2>&1 | head -40
```

Expected: type errors about missing props on `GroupMatches` and `BracketTab` — these will be fixed in the next two tasks.

- [ ] **Step 8: Commit**

```bash
git add src/pages/TournamentPage.tsx
git commit -m "feat: add cloud sync orchestration to TournamentPage"
```

---

## Task 5: Update `GroupMatches` to accept callback props

**Files:**
- Modify: `src/components/tournament/GroupMatches.tsx`

- [ ] **Step 1: Add props interface and replace store calls**

Replace the component signature and internal mutation calls:

```tsx
interface Props {
  onSetMatchScore: (matchId: string, scoreA: number, scoreB: number) => void
  onResetGroups: () => void
}

export default function GroupMatches({ onSetMatchScore, onResetGroups }: Props) {
```

Remove these lines that pull mutations from the store:
```ts
const setMatchScore = useTournamentStore((s) => s.setMatchScore)  // remove
const resetGroups = useTournamentStore((s) => s.resetGroups)       // remove
```

Replace the reset button handler:
```tsx
// old
onClick={() => { if (confirm('Reset group assignment? All scores will be lost.')) resetGroups() }}
// new
onClick={() => { if (confirm('Reset group assignment? All scores will be lost.')) onResetGroups() }}
```

Replace `ScoreModal`'s `onConfirm`:
```tsx
// old
onConfirm={(a, b) => { setMatchScore(activeMatch.id, a, b); setActiveMatch(null) }}
// new
onConfirm={(a, b) => { onSetMatchScore(activeMatch.id, a, b); setActiveMatch(null) }}
```

- [ ] **Step 2: Verify TypeScript compiles**

```bash
npm run build 2>&1 | head -40
```

Expected: error only about `BracketTab` missing prop — `GroupMatches` should be clean.

- [ ] **Step 3: Commit**

```bash
git add src/components/tournament/GroupMatches.tsx
git commit -m "feat: lift setMatchScore and resetGroups out of GroupMatches to props"
```

---

## Task 6: Update `BracketTab` to accept callback prop

**Files:**
- Modify: `src/components/tournament/BracketTab.tsx`

- [ ] **Step 1: Add props interface and replace store call**

```tsx
interface Props {
  onSetMatchScore: (matchId: string, scoreA: number, scoreB: number) => void
}

export default function BracketTab({ onSetMatchScore }: Props) {
```

Remove:
```ts
const setMatchScore = useTournamentStore((s) => s.setMatchScore)  // remove
```

Replace `ScoreModal`'s `onConfirm`:
```tsx
// old
onConfirm={(a, b) => { setMatchScore(activeMatch.id, a, b); setActiveMatch(null) }}
// new
onConfirm={(a, b) => { onSetMatchScore(activeMatch.id, a, b); setActiveMatch(null) }}
```

- [ ] **Step 2: Verify TypeScript compiles with no errors**

```bash
npm run build 2>&1 | head -40
```

Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add src/components/tournament/BracketTab.tsx
git commit -m "feat: lift setMatchScore out of BracketTab to prop"
```

---

## Task 7: Smoke test end-to-end

No test suite exists — manual verification.

- [ ] **Step 1: Start dev server**

```bash
npm run dev
```

- [ ] **Step 2: Test group assignment (localStorage)**

1. Open `http://localhost:5173/tournament`
2. Assign all 16 pairs to groups A/B/C/D
3. Refresh the page — verify group assignment is preserved (localStorage working)
4. Tap "Confirm Groups" — verify matches appear in the Groups tab

- [ ] **Step 3: Test score entry (cloud sync)**

1. Tap a match row in Groups tab → enter a score → Confirm
2. Verify "Saving…" indicator appears in header, then "Saved"
3. Verify no error toast appears
4. Switch to Bracket tab → verify score appears
5. Switch to Standings tab → verify W/L updated

- [ ] **Step 4: Test cloud persistence across refresh**

1. Enter a score
2. Hard-refresh the page (`Cmd+Shift+R`)
3. Verify match scores are restored from cloud (not localStorage)

- [ ] **Step 5: Test reset**

1. In Groups tab, tap "Reset groups"
2. Confirm the dialog
3. Verify groups are cleared and matches disappear

- [ ] **Step 6: Final build check**

```bash
npm run build
```

Expected: clean build with no type errors.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: tournament cloud sync complete"
```
