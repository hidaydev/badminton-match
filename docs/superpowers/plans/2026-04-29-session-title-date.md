# Session Title & Date Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add required `title` and `date` fields to every session — captured on setup, displayed in the summary/view modal, and automatically included in cloud sync.

**Architecture:** `title` and `date` are added to `SessionConfig` in the Zustand store. `SetupPage` collects them before the session locks. `SummaryModal` receives them as new props and renders them at the top; both callers (`GeneratePage` and `SharedSessionPage`) pass them through.

**Tech Stack:** React 19, TypeScript, Zustand, Tailwind v4, Vite

---

## File Map

| File | Change |
|---|---|
| `src/store/index.ts` | Add `title`/`date` to `SessionConfig`; add `setTitle`/`setDate` actions; bump version 11→12 |
| `src/pages/SetupPage.tsx` | Add title text input + date picker at top of form; tighten lock button guard |
| `src/components/SummaryModal.tsx` | Add `title`/`date` props; render session header below toolbar |
| `src/pages/GeneratePage.tsx` | Pass `session.title` and `session.date` to `SummaryModal` |
| `src/pages/SharedSessionPage.tsx` | Pass `snapshot.session.title` and `snapshot.session.date` to `SummaryModal` |

---

### Task 1: Extend the store with `title`, `date`, `setTitle`, `setDate`

**Files:**
- Modify: `src/store/index.ts`

- [ ] **Step 1: Add fields to `SessionConfig` interface**

In `src/store/index.ts`, update `SessionConfig`:

```ts
export interface SessionConfig {
  title: string       // ← add
  date: string        // ← add (ISO date, e.g. "2026-04-29")
  courts: number
  sessionStart: string
  slotMinutes: number
  courtTimes: CourtTime[]
  playerCount: number
  slotsPerCourt: number[]
  totalGames: number
  courtNames: string[]
  tierCount: 3 | 4
  locked: boolean
}
```

- [ ] **Step 2: Add actions to `AppState` interface**

In the `AppState` interface, add after `setTierCount`:

```ts
setTitle: (title: string) => void
setDate: (date: string) => void
```

- [ ] **Step 3: Update `defaultSession` with new fields**

Replace the `defaultSession` constant:

```ts
const defaultSession: SessionConfig = {
  title: '',
  date: new Date().toISOString().slice(0, 10),
  courts: 2,
  sessionStart: '09:00',
  slotMinutes: DEFAULT_SLOT_MINUTES,
  courtTimes: DEFAULT_COURT_TIMES,
  playerCount: 8,
  ...derivedFromCourtTimes(DEFAULT_COURT_TIMES, DEFAULT_SLOT_MINUTES),
  courtNames: [],
  tierCount: 3,
  locked: false,
}
```

- [ ] **Step 4: Add `setTitle` and `setDate` action implementations**

Inside the `create<AppState>()(persist(...))` call, add after `setTierCount`:

```ts
setTitle: (title) =>
  set((s) => ({ session: { ...s.session, title } })),

setDate: (date) =>
  set((s) => ({ session: { ...s.session, date } })),
```

- [ ] **Step 5: Bump the store version**

Change `version: 11` to `version: 12` in the persist config. The existing `migrate` function already resets to defaults, which now include `title: ''` and `date: <today>` — no further changes needed.

- [ ] **Step 6: Verify TypeScript compiles**

```bash
npm run build
```

Expected: build succeeds with no type errors. (It will likely warn about callers of `SummaryModal` missing the new props — that's fine, we fix those next.)

- [ ] **Step 7: Commit**

```bash
git add src/store/index.ts
git commit -m "feat: add title and date fields to SessionConfig"
```

---

### Task 2: Capture title and date on SetupPage

**Files:**
- Modify: `src/pages/SetupPage.tsx`

- [ ] **Step 1: Pull `setTitle` and `setDate` from the store**

In the `SetupPage` component, add `setTitle` and `setDate` to the destructured store values:

```ts
const {
  session,
  setCourts,
  setSessionStart,
  setSlotMinutes,
  setCourtTime,
  setCourtName,
  setPlayerCount,
  setTierCount,
  setTitle,    // ← add
  setDate,     // ← add
  lockSession,
  resetSession,
} = useStore()
```

- [ ] **Step 2: Add title and date inputs at the top of the form card**

Inside the `<div className="bg-slate-900 border border-slate-800 rounded-2xl p-4 flex flex-col gap-5">` card, add a new block **before** `{/* Block 1: Players + Duration */}`:

```tsx
{/* Block 0: Session identity */}
<div className="flex flex-wrap gap-4">
  <div className="flex flex-col gap-1 flex-1 min-w-[180px]">
    <label className="text-xs text-slate-400">Session title</label>
    <input
      type="text"
      value={session.title}
      onChange={(e) => setTitle(e.target.value)}
      placeholder="e.g. Sunday Morning Session"
      disabled={session.locked}
      className="bg-slate-800 border border-slate-700 rounded-lg px-3 py-1.5 text-sm text-white placeholder-slate-500 focus:outline-none focus:border-indigo-500 disabled:opacity-40 disabled:cursor-not-allowed"
    />
  </div>
  <div className="flex flex-col gap-1">
    <label className="text-xs text-slate-400">Date</label>
    <input
      type="date"
      value={session.date}
      onChange={(e) => setDate(e.target.value)}
      disabled={session.locked}
      className="bg-slate-800 border border-slate-700 rounded-lg px-2 py-1.5 text-sm text-white focus:outline-none focus:border-indigo-500 disabled:opacity-40 disabled:cursor-not-allowed cursor-pointer"
    />
  </div>
</div>
```

- [ ] **Step 3: Guard the lock button against empty title or date**

Find the `handleLock` function and the lock button's `disabled` prop. The button currently uses `!!courtError`. Update it to also check for missing title/date:

```tsx
const canLock = !courtError && session.title.trim() !== '' && session.date !== ''

// ...in the JSX:
<button
  onClick={handleLock}
  disabled={!canLock}
  className="w-full py-2.5 bg-indigo-600 hover:bg-indigo-500 active:bg-indigo-700 disabled:opacity-40 disabled:cursor-not-allowed text-white font-semibold rounded-xl transition-colors"
>
  Start Session →
</button>
```

- [ ] **Step 4: Run the dev server and manually verify**

```bash
npm run dev
```

Open `http://localhost:5173`. Confirm:
- Title input and date picker appear at the top of the setup card
- "Start Session →" is disabled when title is empty
- "Start Session →" is disabled when date is cleared
- Filling both enables the button
- After locking, both inputs are disabled (greyed out)
- Date defaults to today

- [ ] **Step 5: Commit**

```bash
git add src/pages/SetupPage.tsx
git commit -m "feat: require title and date on session setup"
```

---

### Task 3: Display title and date in SummaryModal

**Files:**
- Modify: `src/components/SummaryModal.tsx`

- [ ] **Step 1: Add `title` and `date` to the props interface**

Find the props destructuring and type block for `SummaryModal` (starts at line 83). Add `title` and `date`:

```tsx
export default function SummaryModal({
  result,
  playerMap,
  slotsPerCourt,
  courtNames,
  playedGames: playedArr,
  gameScores,
  onTogglePlayedGame,
  onSetGameScore,
  onClose,
  title,
  date,
}: {
  result: GeneratorResult
  playerMap: Map<string, Player>
  slotsPerCourt: number[]
  courtNames: string[]
  playedGames: string[]
  gameScores: Record<string, GameScore>
  onTogglePlayedGame: (key: string) => void
  onSetGameScore: (key: string, a: number, b: number) => void
  onClose: () => void
  title: string
  date: string
})
```

- [ ] **Step 2: Add a session header below the toolbar**

After the closing `</div>` of the `{/* Toolbar */}` div (around line 189), add a session header block:

```tsx
{/* Session header */}
{(title || date) && (
  <div className="px-5 py-3 border-b border-slate-800 shrink-0">
    {title && <p className="text-white font-bold text-base leading-tight">{title}</p>}
    {date && (
      <p className="text-slate-400 text-xs mt-0.5">
        {new Date(date + 'T00:00:00').toLocaleDateString('en-GB', {
          weekday: 'long',
          day: 'numeric',
          month: 'long',
          year: 'numeric',
        })}
      </p>
    )}
  </div>
)}
```

- [ ] **Step 3: Verify TypeScript compiles**

```bash
npm run build
```

Expected: build errors on `GeneratePage` and `SharedSessionPage` missing the new `title` and `date` props — fix those in the next two tasks.

---

### Task 4: Pass title and date from GeneratePage

**Files:**
- Modify: `src/pages/GeneratePage.tsx`

- [ ] **Step 1: Pass `title` and `date` to `SummaryModal`**

Find the `<SummaryModal` render (around line 578). Add `title` and `date` props:

```tsx
{showSummary && result && (
  <SummaryModal
    result={result}
    playerMap={playerMap}
    slotsPerCourt={session.slotsPerCourt}
    courtNames={session.courtNames ?? []}
    playedGames={playedArr}
    gameScores={gameScores}
    onTogglePlayedGame={handleTogglePlayed}
    onSetGameScore={handleSetScore}
    onClose={() => setShowSummary(false)}
    title={session.title}
    date={session.date}
  />
)}
```

- [ ] **Step 2: Verify TypeScript compiles**

```bash
npm run build
```

Expected: only `SharedSessionPage` still errors.

---

### Task 5: Pass title and date from SharedSessionPage

**Files:**
- Modify: `src/pages/SharedSessionPage.tsx`

- [ ] **Step 1: Pass `title` and `date` to `SummaryModal`**

Find the `<SummaryModal` render (around line 90). Add `title` and `date` props:

```tsx
return (
  <SummaryModal
    result={result}
    playerMap={playerMap}
    slotsPerCourt={snapshot.session.slotsPerCourt}
    courtNames={snapshot.session.courtNames ?? []}
    playedGames={playedGames}
    gameScores={gameScores}
    onTogglePlayedGame={handleTogglePlayed}
    onSetGameScore={handleSetScore}
    onClose={() => navigate('/')}
    title={snapshot.session.title ?? ''}
    date={snapshot.session.date ?? ''}
  />
)
```

Note: `?? ''` guards against old sessions in the sheet that predate this feature and have no `title`/`date`.

- [ ] **Step 2: Full build verification**

```bash
npm run build
```

Expected: clean build, zero type errors.

- [ ] **Step 3: End-to-end manual test**

```bash
npm run dev
```

Walk through the full flow:
1. Open `http://localhost:5173` — confirm title input and date picker appear
2. Try clicking "Start Session →" with empty title — confirm disabled
3. Fill in title + date, set courts/players, click "Start Session →"
4. Add players, go to Generate, generate a schedule
5. Open the Summary modal — confirm session title and formatted date appear at the top
6. Publish to cloud (Share button) and open the `/s/:id` URL — confirm title and date appear in the shared view too

- [ ] **Step 4: Commit**

```bash
git add src/components/SummaryModal.tsx src/pages/GeneratePage.tsx src/pages/SharedSessionPage.tsx
git commit -m "feat: show session title and date in summary and shared view"
```
