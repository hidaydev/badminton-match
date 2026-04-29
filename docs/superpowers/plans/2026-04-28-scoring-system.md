# Scoring System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-game score entry (expandable inline panel in the Summary modal) and a live Standings tab showing each player's W-L, point diff, and total points.

**Architecture:** Scores are stored in Zustand as `gameScores: Record<string, {a,b}>` keyed by `"slot-court"` (same key format as `playedGames`). A pure `computeStandings` utility derives individual player stats from the schedule + scores. The `SummaryModal` gains tabs (Schedule / Standings) and an expandable score panel per game row.

**Tech Stack:** React 19, TypeScript, Zustand (persist middleware), Tailwind v4

> **Note:** No test suite exists. Verification uses `npm run build` (TypeScript type-check + Vite build) and manual browser checks via `npm run dev`.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `src/store/index.ts` | Modify | Add `gameScores`, `setGameScore`, `clearGameScore`; reset on `setResult`; bump version |
| `src/utils/standings.ts` | Create | Pure `computeStandings()` function — derives player standings from schedule + scores |
| `src/pages/GeneratePage.tsx` | Modify | Add tabs + expandable score panel to `SummaryModal`; add `StandingsTab` component |

---

## Task 1: Extend the store with game scores

**Files:**
- Modify: `src/store/index.ts`

- [ ] **Step 1: Add the `GameScore` type and extend `AppState`**

In `src/store/index.ts`, add the `GameScore` type after the existing `ScheduleSlot` interface (around line 27), and add `gameScores` + its two actions to the `AppState` interface:

```ts
// After ScheduleSlot interface:
export interface GameScore {
  a: number  // Team A score
  b: number  // Team B score
}
```

In the `AppState` interface, add after `playedGames: string[]`:

```ts
gameScores: Record<string, GameScore>

setGameScore: (key: string, a: number, b: number) => void
clearGameScore: (key: string) => void
```

- [ ] **Step 2: Add initial state value**

In the `create<AppState>()` call, the initial state object has `playedGames: [], summaryOpen: false` on line 127. Add `gameScores: {}` right after `playedGames: []`:

```ts
schedule: [], lastResult: null, playedGames: [], gameScores: {}, summaryOpen: false,
```

- [ ] **Step 3: Add the two new actions**

After the `togglePlayedGame` action (around line 251), add:

```ts
setGameScore: (key, a, b) =>
  set((s) => ({ gameScores: { ...s.gameScores, [key]: { a, b } } })),

clearGameScore: (key) =>
  set((s) => {
    const next = { ...s.gameScores }
    delete next[key]
    return { gameScores: next }
  }),
```

- [ ] **Step 4: Reset `gameScores` in `setResult`**

Find `setResult` (line 249):

```ts
setResult: (r) => set({ schedule: r.schedule, lastResult: r, playedGames: [] }),
```

Change to:

```ts
setResult: (r) => set({ schedule: r.schedule, lastResult: r, playedGames: [], gameScores: {} }),
```

- [ ] **Step 5: Reset `gameScores` in `resetSession`**

Find `resetSession` (line 200). Add `gameScores: {}` to the reset object:

```ts
resetSession: () =>
  set({ sessionId: nanoid(), session: defaultSession, players: [], fixMatches: [], schedule: [], lastResult: null, playedGames: [], gameScores: {}, summaryOpen: false }),
```

- [ ] **Step 6: Also add `gameScores: {}` to the migrate function**

Find the `migrate` function near the bottom:

```ts
migrate: () => ({
  sessionId: nanoid(),
  session: defaultSession,
  players: [],
  fixMatches: [],
  schedule: [], lastResult: null, playedGames: [], summaryOpen: false,
}),
```

Change to:

```ts
migrate: () => ({
  sessionId: nanoid(),
  session: defaultSession,
  players: [],
  fixMatches: [],
  schedule: [], lastResult: null, playedGames: [], gameScores: {}, summaryOpen: false,
}),
```

- [ ] **Step 7: Bump store version from 10 to 11**

Find `version: 10` and change to `version: 11`.

- [ ] **Step 8: Verify types compile**

```bash
npm run build
```

Expected: build succeeds with no TypeScript errors.

- [ ] **Step 9: Commit**

```bash
git add src/store/index.ts
git commit -m "feat: add gameScores to store with setGameScore/clearGameScore actions"
```

---

## Task 2: Pure standings computation utility

**Files:**
- Create: `src/utils/standings.ts`

- [ ] **Step 1: Create the file with types and the `computeStandings` function**

```ts
import type { Player, ScheduleSlot, GameScore } from '../store'

export interface PlayerStanding {
  player: Player
  wins: number
  losses: number
  pointsFor: number
  pointsAgainst: number
  diff: number
}

export function computeStandings(
  players: Player[],
  schedule: ScheduleSlot[],
  gameScores: Record<string, GameScore>,
): PlayerStanding[] {
  const map = new Map<string, PlayerStanding>()

  for (const p of players) {
    map.set(p.id, { player: p, wins: 0, losses: 0, pointsFor: 0, pointsAgainst: 0, diff: 0 })
  }

  for (const slot of schedule) {
    const key = `${slot.slot}-${slot.court}`
    const score = gameScores[key]
    if (!score) continue

    const { a, b } = score
    const teamAWon = a > b

    for (const id of slot.teamA) {
      const s = map.get(id)
      if (!s) continue
      if (teamAWon) s.wins++ else s.losses++
      s.pointsFor += a
      s.pointsAgainst += b
    }

    for (const id of slot.teamB) {
      const s = map.get(id)
      if (!s) continue
      if (!teamAWon) s.wins++ else s.losses++
      s.pointsFor += b
      s.pointsAgainst += a
    }
  }

  for (const s of map.values()) {
    s.diff = s.pointsFor - s.pointsAgainst
  }

  return [...map.values()].sort((a, b) => {
    if (b.wins !== a.wins) return b.wins - a.wins
    if (b.diff !== a.diff) return b.diff - a.diff
    return b.pointsFor - a.pointsFor
  })
}
```

- [ ] **Step 2: Verify types compile**

```bash
npm run build
```

Expected: build succeeds with no TypeScript errors.

- [ ] **Step 3: Commit**

```bash
git add src/utils/standings.ts
git commit -m "feat: add computeStandings utility"
```

---

## Task 3: Score entry panel in SummaryModal

**Files:**
- Modify: `src/pages/GeneratePage.tsx`

This task adds the `+ score` / `▲ score` toggle and expandable score panel to each game row inside `SummaryModal`. The Standings tab comes in Task 4.

- [ ] **Step 1: Import new store actions and add `expandedScore` state**

At the top of `SummaryModal`, the component already reads `playedArr` and `togglePlayedGame` from the store. Add the two new selectors right after:

```ts
const gameScores = useStore((s) => s.gameScores)
const setGameScore = useStore((s) => s.setGameScore)
```

Add local state for the currently-open score panel (after the existing `const played = new Set(playedArr)` line):

```ts
const [expandedScore, setExpandedScore] = useState<string | null>(null)
const [scoreError, setScoreError] = useState<string | null>(null)
const [draftScores, setDraftScores] = useState<Record<string, { a: string; b: string }>>({})
```

`draftScores` holds the in-progress text for the inputs before they are committed on blur.

- [ ] **Step 2: Add a `handleScoreBlur` function inside `SummaryModal`**

Add this function inside `SummaryModal`, before the `return` statement:

```ts
function handleScoreBlur(key: string) {
  const draft = draftScores[key]
  if (!draft) return
  const a = parseInt(draft.a, 10)
  const b = parseInt(draft.b, 10)
  if (isNaN(a) || isNaN(b)) return
  if (a < 0 || a > 99 || b < 0 || b > 99) return
  if (a === b) { setScoreError('Scores can\'t be equal'); return }
  setScoreError(null)
  setGameScore(key, a, b)
  if (!played.has(key)) togglePlayedGame(key)
}
```

- [ ] **Step 3: Replace the existing game row `<div>` inside the `games.map(...)` with a version that includes the score toggle and panel**

Find this section inside `SummaryModal`'s return (the `games.map((g) => { ... })` block, roughly lines 82–108). Replace the entire `return (...)` inside that map with:

```tsx
const key = `${s}-${g.court}`
const done = played.has(key)
const savedScore = gameScores[key]
const isOpen = expandedScore === key
const draft = draftScores[key] ?? { a: savedScore ? String(savedScore.a) : '', b: savedScore ? String(savedScore.b) : '' }
const teamANames = g.teamA.map((id) => playerMap.get(id)?.name ?? id).join(' & ')
const teamBNames = g.teamB.map((id) => playerMap.get(id)?.name ?? id).join(' & ')

return (
  <div key={g.court} className="flex flex-col gap-1">
    {/* Game row header */}
    <div
      className={`flex items-center gap-2 select-none rounded-lg px-1 py-0.5 -mx-1 transition-colors ${done ? 'opacity-40' : 'hover:bg-slate-800/40'}`}
    >
      {/* Played checkbox */}
      <div
        className={`w-4 h-4 shrink-0 rounded border flex items-center justify-center transition-colors cursor-pointer ${done ? 'bg-emerald-600 border-emerald-500' : 'border-slate-600 bg-slate-800'}`}
        onClick={() => togglePlayedGame(key)}
      >
        {done && <span className="text-white text-[10px] font-bold leading-none">✓</span>}
      </div>
      {/* Teams */}
      <div className="grid items-center gap-2 flex-1 min-w-0" style={{ gridTemplateColumns: 'auto 1fr auto 1fr' }}>
        <span className="text-[10px] font-semibold text-slate-600 whitespace-nowrap">
          {courtLabel(g.court)}
        </span>
        <span className={`text-sm font-medium ${done ? 'text-slate-500 line-through' : 'text-white'}`}>
          {name(g.teamA[0], s)} &amp; {name(g.teamA[1], s)}
        </span>
        <span className="text-slate-600 text-xs text-center">vs</span>
        <span className={`text-sm font-medium ${done ? 'text-slate-500 line-through' : 'text-white'}`}>
          {name(g.teamB[0], s)} &amp; {name(g.teamB[1], s)}
        </span>
      </div>
      {/* Score toggle / saved score */}
      {savedScore && !isOpen ? (
        <button
          onClick={() => { setExpandedScore(key); setDraftScores((d) => ({ ...d, [key]: { a: String(savedScore.a), b: String(savedScore.b) } })) }}
          className="text-[11px] font-bold text-emerald-400 shrink-0 whitespace-nowrap hover:text-emerald-300"
        >
          {savedScore.a}–{savedScore.b}
        </button>
      ) : (
        <button
          onClick={() => {
            if (isOpen) { setExpandedScore(null); setScoreError(null) }
            else { setExpandedScore(key); setDraftScores((d) => ({ ...d, [key]: draft })) }
          }}
          className="text-[10px] text-slate-600 hover:text-slate-400 shrink-0 whitespace-nowrap transition-colors"
        >
          {isOpen ? '▲ score' : '+ score'}
        </button>
      )}
    </div>

    {/* Expandable score panel */}
    {isOpen && (
      <div className="ml-6 bg-slate-900 border border-indigo-800/60 rounded-lg px-3 py-2.5 flex flex-col gap-2">
        <div className="flex items-center justify-center gap-3">
          <div className="flex flex-col items-center gap-1">
            <span className="text-[10px] text-slate-500 truncate max-w-[80px] text-center">{teamANames}</span>
            <input
              type="number"
              min={0}
              max={99}
              value={draft.a}
              onChange={(e) => setDraftScores((d) => ({ ...d, [key]: { ...draft, a: e.target.value } }))}
              onBlur={() => handleScoreBlur(key)}
              className="w-14 bg-slate-800 border border-indigo-700 rounded-lg px-2 py-1.5 text-white font-bold text-lg text-center focus:outline-none focus:border-indigo-500"
            />
          </div>
          <span className="text-slate-600 font-bold text-lg mt-4">–</span>
          <div className="flex flex-col items-center gap-1">
            <span className="text-[10px] text-slate-500 truncate max-w-[80px] text-center">{teamBNames}</span>
            <input
              type="number"
              min={0}
              max={99}
              value={draft.b}
              onChange={(e) => setDraftScores((d) => ({ ...d, [key]: { ...draft, b: e.target.value } }))}
              onBlur={() => handleScoreBlur(key)}
              className="w-14 bg-slate-800 border border-slate-700 rounded-lg px-2 py-1.5 text-slate-300 font-bold text-lg text-center focus:outline-none focus:border-indigo-500"
            />
          </div>
        </div>
        {scoreError && (
          <p className="text-[10px] text-red-400 text-center">{scoreError}</p>
        )}
      </div>
    )}
  </div>
)
```

- [ ] **Step 4: Add `useState` to the import at the top of the file if not already present**

The file already imports `useState` at line 1: `import { useState } from 'react'` — no change needed.

- [ ] **Step 5: Verify types compile and check in browser**

```bash
npm run build
```

Expected: no TypeScript errors.

```bash
npm run dev
```

Open the app, generate a schedule, open the Summary. Each game row should show `+ score`. Tapping it should expand the panel with two number inputs. Entering scores and tabbing/clicking away should save them (score shown as `21–15` in green). Equal scores should show the error message.

- [ ] **Step 6: Commit**

```bash
git add src/pages/GeneratePage.tsx
git commit -m "feat: add inline score entry panel to SummaryModal"
```

---

## Task 4: Tabs and StandingsTab in SummaryModal

**Files:**
- Modify: `src/pages/GeneratePage.tsx`

- [ ] **Step 1: Import `computeStandings`**

At the top of `src/pages/GeneratePage.tsx`, add after the existing imports:

```ts
import { computeStandings } from '../utils/standings'
```

- [ ] **Step 2: Add `activeTab` state to `SummaryModal`**

Inside `SummaryModal`, add alongside the existing state declarations:

```ts
const [activeTab, setActiveTab] = useState<'schedule' | 'standings'>('schedule')
```

- [ ] **Step 3: Replace the toolbar with a tabbed version**

Find the current toolbar `<div>` inside `SummaryModal` (the `flex items-center justify-between px-5 py-3 border-b` div, lines 54–69). Replace it with:

```tsx
<div className="flex items-center justify-between px-5 py-3 border-b border-slate-800 shrink-0">
  <div className="flex items-center gap-3">
    <div className="flex gap-1">
      <button
        onClick={() => setActiveTab('schedule')}
        className={`text-xs font-semibold px-3 py-1.5 rounded-lg transition-colors ${activeTab === 'schedule' ? 'bg-indigo-900/60 border border-indigo-700 text-indigo-300' : 'text-slate-500 hover:text-slate-300'}`}
      >
        Schedule
      </button>
      <button
        onClick={() => setActiveTab('standings')}
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
  <button
    onClick={onClose}
    className="text-slate-400 hover:text-white px-3 py-1.5 rounded-lg hover:bg-slate-800 transition-colors text-sm"
  >
    Close
  </button>
</div>
```

- [ ] **Step 4: Wrap the schedule content in a conditional and add the StandingsTab**

Find the `{/* Content */}` section (the `<div className="flex-1 overflow-auto px-4 py-4 ...">` block). Wrap its inner content so only the schedule list shows when `activeTab === 'schedule'`, and render standings when `activeTab === 'standings'`:

```tsx
{/* Content */}
<div className="flex-1 overflow-auto px-4 py-4 max-w-xl mx-auto w-full">
  {activeTab === 'schedule' ? (
    <div className="flex flex-col divide-y divide-slate-800">
      {/* The Array.from({ length: maxSlots }, ...) slot-rendering block
          written in Task 3 stays here exactly as-is — no edits needed */}
    </div>
  ) : (
    <StandingsTab
      players={[...playerMap.values()]}
      schedule={result.schedule}
      gameScores={gameScores}
    />
  )}
</div>
```

- [ ] **Step 5: Add the `StandingsTab` component above `SummaryModal`**

Add this new component directly above the `SummaryModal` function definition:

```tsx
function ordinal(n: number): string {
  const s = ['th', 'st', 'nd', 'rd']
  const v = n % 100
  return n + (s[(v - 20) % 10] ?? s[v] ?? s[0])
}

function StandingsTab({
  players,
  schedule,
  gameScores,
}: {
  players: Player[]
  schedule: import('../store').ScheduleSlot[]
  gameScores: Record<string, import('../store').GameScore>
}) {
  const standings = computeStandings(players, schedule, gameScores)
  const hasScores = Object.keys(gameScores).length > 0

  if (!hasScores) {
    return (
      <div className="flex items-center justify-center min-h-[200px]">
        <p className="text-sm text-slate-500 text-center">Enter scores in the Schedule tab to see standings.</p>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-1.5">
      {/* Header */}
      <div className="grid items-center gap-2 px-2 mb-1" style={{ gridTemplateColumns: '36px 1fr 44px 36px 44px' }}>
        <span className="text-[10px] font-bold text-slate-600 text-center">#</span>
        <span className="text-[10px] font-bold text-slate-600">Name</span>
        <span className="text-[10px] font-bold text-slate-600 text-center">W-L</span>
        <span className="text-[10px] font-bold text-slate-600 text-center">Diff</span>
        <span className="text-[10px] font-bold text-slate-600 text-center">Pts</span>
      </div>

      {standings.map((s, i) => {
        const rank = i + 1
        const isFirst = rank === 1
        const isSecond = rank === 2
        const wlColor = s.wins > s.losses ? 'text-emerald-400' : s.losses > s.wins ? 'text-red-400' : 'text-slate-400'
        const diffColor = s.diff > 0 ? 'text-emerald-400' : s.diff < 0 ? 'text-red-400' : 'text-slate-400'
        const diffLabel = s.diff > 0 ? `+${s.diff}` : String(s.diff)

        return (
          <div
            key={s.player.id}
            className={`grid items-center gap-2 px-2 py-2 rounded-xl border ${
              isFirst
                ? 'bg-emerald-900/20 border-emerald-800/60'
                : isSecond
                ? 'bg-emerald-900/10 border-emerald-900/40'
                : 'bg-slate-800/50 border-slate-700/50'
            }`}
            style={{ gridTemplateColumns: '36px 1fr 44px 36px 44px' }}
          >
            <span className={`text-[11px] font-bold text-center ${isFirst ? 'text-amber-400' : 'text-slate-500'}`}>
              {ordinal(rank)}
            </span>
            <span className="text-sm font-medium text-white truncate">{s.player.name}</span>
            <span className={`text-[11px] font-semibold text-center ${wlColor}`}>{s.wins}-{s.losses}</span>
            <span className={`text-[11px] font-semibold text-center ${diffColor}`}>{diffLabel}</span>
            <span className="text-sm font-bold text-white text-center">{s.pointsFor}</span>
          </div>
        )
      })}
    </div>
  )
}
```

- [ ] **Step 6: Pass `gameScores` into `StandingsTab` — ensure it's read from store in `SummaryModal`**

`gameScores` is already read from the store in Task 3 Step 1 (`const gameScores = useStore((s) => s.gameScores)`). No additional change needed.

- [ ] **Step 7: Verify types compile and test in browser**

```bash
npm run build
```

Expected: no TypeScript errors.

```bash
npm run dev
```

- Generate a schedule → open Summary
- Verify two tabs appear: "Schedule" and "Standings"
- Enter scores for a few games in Schedule tab
- Switch to Standings tab — players should be ranked with W-L / Diff / Pts
- Standings tab with no scores should show the empty state message

- [ ] **Step 8: Commit**

```bash
git add src/pages/GeneratePage.tsx src/utils/standings.ts
git commit -m "feat: add Standings tab to SummaryModal with live player rankings"
```

---

## Self-Review Checklist

### Spec coverage

| Spec requirement | Task |
|-----------------|------|
| `gameScores` store field with `{a, b}` | Task 1 |
| `setGameScore` / `clearGameScore` actions | Task 1 |
| `setResult` resets `gameScores` | Task 1 |
| Store version bump 10→11 | Task 1 |
| `resetSession` resets `gameScores` | Task 1 |
| Pure standings computation (wins, losses, pointsFor, pointsAgainst, diff) | Task 2 |
| Sort: wins → diff → pts | Task 2 |
| `+ score` / `▲ score` toggle button on every game row | Task 3 |
| Expandable score panel with team-labelled number inputs | Task 3 |
| Save on blur, both fields required | Task 3 |
| Equal scores rejected with error message | Task 3 |
| Auto-mark game as played when score saved | Task 3 |
| Saved score shown inline (`21–15`) in green | Task 3 |
| One panel open at a time | Task 3 |
| Schedule / Standings tabs in SummaryModal toolbar | Task 4 |
| Standings table: rank / name / W-L / diff / pts | Task 4 |
| Rank 1 gold + green tint, rank 2 lighter tint | Task 4 |
| W-L colour (green/red/neutral) | Task 4 |
| Empty state when no scores entered | Task 4 |
| Shared view: no score entry (score panel only in SummaryModal which shared view doesn't use differently — shared view has no store writes, this is naturally handled) | — |
