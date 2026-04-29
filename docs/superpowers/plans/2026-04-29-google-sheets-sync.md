# Google Sheets Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add cloud sync via Google Apps Script + Google Sheets so sessions can be shared with a short URL (`/s/:sessionId`), and all devices can read and update scores and the game checklist.

**Architecture:** A Google Apps Script Web App acts as a REST API, reading/writing session JSON to a Google Sheet ("Sessions" tab, one row per session). The frontend gains a cloud Share button that publishes state and returns a short URL. A new `SharedSessionPage` route fetches state from cloud and renders the existing `SummaryModal` with write-back on every checklist or score change.

**Tech Stack:** React 19, Zustand, TypeScript, Vite, Google Apps Script (GAS), `fetch()` for REST calls.

---

## File Map

| Action | File | Purpose |
|--------|------|---------|
| Create | `apps-script/Code.gs` | Apps Script web app — REST API backed by Google Sheet |
| Create | `.env.local.example` | Documents `VITE_APPS_SCRIPT_URL` env var |
| Create | `src/utils/cloudSync.ts` | `CloudSnapshot` type + `getSession` / `publishSession` wrappers |
| Modify | `src/store/index.ts` | Add `cloudSessionId: string \| null` + `setCloudSessionId` action |
| Modify | `src/pages/GeneratePage.tsx` | Lift store reads out of `SummaryModal` into props; add `onRefresh?` prop; wire cloud Share button |
| Create | `src/components/ShareButton.tsx` | Cloud share button — publishes state, shows copyable short URL |
| Create | `src/pages/SharedSessionPage.tsx` | `/s/:sessionId` page — fetches cloud state, renders `SummaryModal`, writes back on change |
| Modify | `src/App.tsx` | Register `/s/:sessionId` → `SharedSessionPage` route |

---

### Task 1: Apps Script code

Create the Apps Script file that will be pasted into the Google Drive editor and deployed as a Web App.

**Files:**
- Create: `apps-script/Code.gs`

- [ ] **Step 1: Create the file**

```javascript
// apps-script/Code.gs
// Deploy as Web App: Execute as Me, Who has access: Anyone.
// GET  ?id=<sessionId>            → { ok: true, data: {...} } or { ok: false, error: "not found" }
// POST body (text/plain JSON str) → { ok: true } or { ok: false, error: "..." }

var SHEET_NAME = 'Sessions';

function getSheet() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(SHEET_NAME);
  if (!sheet) {
    sheet = ss.insertSheet(SHEET_NAME);
    sheet.appendRow(['session_id', 'created_at', 'updated_at', 'data']);
  }
  return sheet;
}

function doGet(e) {
  var id = e.parameter.id;
  if (!id) return respond({ ok: false, error: 'missing id' });

  var sheet = getSheet();
  var values = sheet.getDataRange().getValues();

  for (var i = 1; i < values.length; i++) {
    if (values[i][0] === id) {
      var data = JSON.parse(values[i][3]);
      return respond({ ok: true, data: data });
    }
  }

  return respond({ ok: false, error: 'not found' });
}

function doPost(e) {
  var payload;
  try {
    payload = JSON.parse(e.postData.contents);
  } catch (err) {
    return respond({ ok: false, error: 'invalid JSON' });
  }

  var id = payload.id;
  var data = payload.data;
  if (!id || !data) return respond({ ok: false, error: 'missing id or data' });

  var sheet = getSheet();
  var values = sheet.getDataRange().getValues();
  var now = new Date().toISOString();

  for (var i = 1; i < values.length; i++) {
    if (values[i][0] === id) {
      sheet.getRange(i + 1, 3).setValue(now);
      sheet.getRange(i + 1, 4).setValue(JSON.stringify(data));
      return respond({ ok: true });
    }
  }

  sheet.appendRow([id, now, now, JSON.stringify(data)]);
  return respond({ ok: true });
}

function respond(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
```

- [ ] **Step 2: Commit**

```bash
git add apps-script/Code.gs
git commit -m "feat: add Apps Script web app for session storage"
```

---

### Task 2: Environment variable setup

**Files:**
- Create: `.env.local.example`

- [ ] **Step 1: Create the example env file**

```bash
# .env.local.example
# Copy to .env.local and fill in your Apps Script deployment URL.
# Get this URL after deploying Code.gs as a Web App in Google Drive.
VITE_APPS_SCRIPT_URL=https://script.google.com/macros/s/YOUR_DEPLOYMENT_ID/exec
```

- [ ] **Step 2: Add .env.local to .gitignore (if not already there)**

Open `.gitignore`. If `*.local` is already listed (it is — Vite's default), `.env.local` is already ignored. No change needed.

- [ ] **Step 3: Commit**

```bash
git add .env.local.example
git commit -m "docs: add env var example for Apps Script URL"
```

---

### Task 3: cloudSync utility

**Files:**
- Create: `src/utils/cloudSync.ts`

- [ ] **Step 1: Create the file**

```typescript
// src/utils/cloudSync.ts
import type { SessionConfig, Player, FixMatch, ScheduleSlot, GameScore } from '../store'

export interface CloudSnapshot {
  session: SessionConfig
  players: Player[]
  fixMatches: FixMatch[]
  schedule: ScheduleSlot[]
  playedGames: string[]
  gameScores: Record<string, GameScore>
}

function scriptUrl(): string {
  const url = import.meta.env.VITE_APPS_SCRIPT_URL as string
  if (!url) throw new Error('VITE_APPS_SCRIPT_URL is not set')
  return url
}

export async function getSession(id: string): Promise<CloudSnapshot | null> {
  const res = await fetch(`${scriptUrl()}?id=${encodeURIComponent(id)}`)
  const json = await res.json() as { ok: boolean; data?: CloudSnapshot; error?: string }
  if (!json.ok) return null
  return json.data ?? null
}

export async function publishSession(id: string, data: CloudSnapshot): Promise<void> {
  const res = await fetch(scriptUrl(), {
    method: 'POST',
    // text/plain avoids CORS preflight; Apps Script reads via e.postData.contents
    body: JSON.stringify({ id, data }),
  })
  const json = await res.json() as { ok: boolean; error?: string }
  if (!json.ok) throw new Error(json.error ?? 'publish failed')
}
```

- [ ] **Step 2: Commit**

```bash
git add src/utils/cloudSync.ts
git commit -m "feat: add cloudSync utility for Apps Script REST calls"
```

---

### Task 4: Add cloudSessionId to store

**Files:**
- Modify: `src/store/index.ts`

- [ ] **Step 1: Add `cloudSessionId` field and `setCloudSessionId` action to the `AppState` interface**

In `src/store/index.ts`, find the `interface AppState` block and add after `gameScores: Record<string, GameScore>`:

```typescript
  cloudSessionId: string | null
  setCloudSessionId: (id: string) => void
```

- [ ] **Step 2: Add the initial value in the `create` call**

Find the line:
```typescript
      sessionId: nanoid(),
      session: defaultSession,
      players: [],
      fixMatches: [],
      schedule: [], lastResult: null, playedGames: [], gameScores: {}, summaryOpen: false,
```

Replace with:
```typescript
      sessionId: nanoid(),
      session: defaultSession,
      players: [],
      fixMatches: [],
      schedule: [], lastResult: null, playedGames: [], gameScores: {}, summaryOpen: false,
      cloudSessionId: null,
```

- [ ] **Step 3: Add the action implementation**

Find `setSummaryOpen: (open) => set({ summaryOpen: open }),` and add after it:

```typescript
      setCloudSessionId: (id) => set({ cloudSessionId: id }),
```

- [ ] **Step 4: Build to verify types**

```bash
npm run build
```

Expected: build succeeds with no TypeScript errors.

- [ ] **Step 5: Commit**

```bash
git add src/store/index.ts
git commit -m "feat: add cloudSessionId field to store"
```

---

### Task 5: Refactor SummaryModal to use props instead of store

`SummaryModal` currently reads `playedGames`, `gameScores`, `togglePlayedGame`, `setGameScore` directly from the Zustand store. These need to become props so `SharedSessionPage` can pass its own cloud-backed state instead.

**Files:**
- Modify: `src/pages/GeneratePage.tsx`

- [ ] **Step 1: Update the `SummaryModal` props interface**

Find the `SummaryModal` function signature (around line 79):
```typescript
function SummaryModal({
  result,
  playerMap,
  slotsPerCourt,
  courtNames,
  onClose,
}: {
  result: GeneratorResult
  playerMap: Map<string, Player>
  slotsPerCourt: number[]
  courtNames: string[]
  onClose: () => void
})
```

Replace with:
```typescript
function SummaryModal({
  result,
  playerMap,
  slotsPerCourt,
  courtNames,
  playedGames: playedArr,
  gameScores,
  onTogglePlayedGame,
  onSetGameScore,
  onClose,
  onRefresh,
}: {
  result: GeneratorResult
  playerMap: Map<string, Player>
  slotsPerCourt: number[]
  courtNames: string[]
  playedGames: string[]
  gameScores: Record<string, import('../store').GameScore>
  onTogglePlayedGame: (key: string) => void
  onSetGameScore: (key: string, a: number, b: number) => void
  onClose: () => void
  onRefresh?: () => void
})
```

- [ ] **Step 2: Remove the four store reads inside SummaryModal**

Find and delete these four lines (around lines 94–97):
```typescript
  const playedArr = useStore((s) => s.playedGames)
  const togglePlayedGame = useStore((s) => s.togglePlayedGame)
  const gameScores = useStore((s) => s.gameScores)
  const setGameScore = useStore((s) => s.setGameScore)
```

- [ ] **Step 3: Replace store action calls with prop calls inside SummaryModal**

Find (inside `trySaveScore`):
```typescript
    setGameScore(key, a, b)
    if (!played.has(key)) togglePlayedGame(key)
```
Replace with:
```typescript
    onSetGameScore(key, a, b)
    if (!played.has(key)) onTogglePlayedGame(key)
```

Find the checkbox `onClick`:
```typescript
                            onClick={() => togglePlayedGame(key)}
```
Replace with:
```typescript
                            onClick={() => onTogglePlayedGame(key)}
```

- [ ] **Step 4: Add Refresh button to the SummaryModal toolbar**

In the toolbar `div` (the one with `flex items-center justify-between`), find the Close button:
```typescript
        <button
          onClick={onClose}
          className="text-slate-400 hover:text-white px-3 py-1.5 rounded-lg hover:bg-slate-800 transition-colors text-sm"
        >
          Close
        </button>
```

Replace with:
```typescript
        <div className="flex items-center gap-2">
          {onRefresh && (
            <button
              onClick={onRefresh}
              className="text-slate-400 hover:text-white px-3 py-1.5 rounded-lg hover:bg-slate-800 transition-colors text-sm"
            >
              ↺ Refresh
            </button>
          )}
          <button
            onClick={onClose}
            className="text-slate-400 hover:text-white px-3 py-1.5 rounded-lg hover:bg-slate-800 transition-colors text-sm"
          >
            Close
          </button>
        </div>
```

- [ ] **Step 5: Update SummaryModal usage in GeneratePage**

First, add these store reads in `GeneratePage` (near where `showSummary` is read, around line 709):
```typescript
  const playedArr = useStore((s) => s.playedGames)
  const gameScores = useStore((s) => s.gameScores)
  const togglePlayedGame = useStore((s) => s.togglePlayedGame)
  const setGameScore = useStore((s) => s.setGameScore)
```

Then find the `SummaryModal` usage (around line 917):
```typescript
      {showSummary && result && (
        <SummaryModal
          result={result}
          playerMap={playerMap}
          slotsPerCourt={session.slotsPerCourt}
          courtNames={session.courtNames ?? []}
          onClose={() => setShowSummary(false)}
        />
      )}
```

Replace with:
```typescript
      {showSummary && result && (
        <SummaryModal
          result={result}
          playerMap={playerMap}
          slotsPerCourt={session.slotsPerCourt}
          courtNames={session.courtNames ?? []}
          playedGames={playedArr}
          gameScores={gameScores}
          onTogglePlayedGame={togglePlayedGame}
          onSetGameScore={setGameScore}
          onClose={() => setShowSummary(false)}
        />
      )}
```

- [ ] **Step 6: Build to verify**

```bash
npm run build
```

Expected: build succeeds, no TypeScript errors.

- [ ] **Step 7: Commit**

```bash
git add src/pages/GeneratePage.tsx
git commit -m "refactor: lift playedGames/gameScores out of SummaryModal into props"
```

---

### Task 6: ShareButton component

**Files:**
- Create: `src/components/ShareButton.tsx`

- [ ] **Step 1: Create the file**

```typescript
// src/components/ShareButton.tsx
import { useState } from 'react'
import { useStore } from '../store'
import { publishSession, type CloudSnapshot } from '../utils/cloudSync'

function nanoid6(): string {
  return Math.random().toString(36).slice(2, 8)
}

export default function ShareButton() {
  const session = useStore((s) => s.session)
  const players = useStore((s) => s.players)
  const fixMatches = useStore((s) => s.fixMatches)
  const schedule = useStore((s) => s.schedule)
  const playedGames = useStore((s) => s.playedGames)
  const gameScores = useStore((s) => s.gameScores)
  const cloudSessionId = useStore((s) => s.cloudSessionId)
  const setCloudSessionId = useStore((s) => s.setCloudSessionId)

  const [state, setState] = useState<'idle' | 'loading' | 'done' | 'error'>('idle')
  const [shareUrl, setShareUrl] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)

  async function handleShare() {
    setState('loading')
    const id = cloudSessionId ?? nanoid6()
    const snapshot: CloudSnapshot = { session, players, fixMatches, schedule, playedGames, gameScores }
    try {
      await publishSession(id, snapshot)
      setCloudSessionId(id)
      const url = `${window.location.origin}/s/${id}`
      setShareUrl(url)
      setState('done')
    } catch {
      setState('error')
    }
  }

  async function handleCopy() {
    if (!shareUrl) return
    await navigator.clipboard.writeText(shareUrl)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  if (state === 'done' && shareUrl) {
    return (
      <div className="flex items-center gap-2 px-3 py-2 rounded-xl bg-slate-800 border border-slate-700">
        <span className="text-xs text-slate-400 truncate max-w-[200px]">{shareUrl}</span>
        <button
          onClick={handleCopy}
          className={`text-xs font-semibold shrink-0 transition-colors ${copied ? 'text-emerald-400' : 'text-indigo-400 hover:text-white'}`}
        >
          {copied ? '✓ Copied!' : 'Copy'}
        </button>
        <button
          onClick={() => { setState('idle'); setShareUrl(null) }}
          className="text-slate-600 hover:text-slate-400 text-xs shrink-0"
        >
          ✕
        </button>
      </div>
    )
  }

  return (
    <button
      onClick={handleShare}
      disabled={state === 'loading'}
      className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium bg-indigo-900/50 hover:bg-indigo-800 border border-indigo-700 text-indigo-300 hover:text-white transition-colors disabled:opacity-50"
    >
      {state === 'loading' ? (
        'Publishing…'
      ) : state === 'error' ? (
        '✕ Failed — retry?'
      ) : cloudSessionId ? (
        '↑ Re-publish'
      ) : (
        <>
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/>
            <line x1="8.59" y1="13.51" x2="15.42" y2="17.49"/><line x1="15.41" y1="6.51" x2="8.59" y2="10.49"/>
          </svg>
          Share
        </>
      )}
    </button>
  )
}
```

- [ ] **Step 2: Commit**

```bash
git add src/components/ShareButton.tsx
git commit -m "feat: add ShareButton component for cloud publishing"
```

---

### Task 7: Add ShareButton to GeneratePage

**Files:**
- Modify: `src/pages/GeneratePage.tsx`

- [ ] **Step 1: Import ShareButton at the top of GeneratePage.tsx**

Find the existing imports at the top of the file and add:
```typescript
import ShareButton from '../components/ShareButton'
```

- [ ] **Step 2: Render ShareButton after the schedule, when a result exists and not in shared view**

Find this block (around line 843):
```typescript
      {result && (
        <div className="flex gap-1.5 shrink-0">
          <button
            onClick={() => setShowSummary(true)}
```

Replace with:
```typescript
      {result && (
        <div className="flex gap-1.5 shrink-0 flex-wrap">
          <button
            onClick={() => setShowSummary(true)}
```

Then find the closing of that `<div className="flex gap-1.5 shrink-0">` block (it ends before the `</div>` of the outer `flex wrap` row). Add `ShareButton` inside, after the existing buttons but only when not in shared view. Find the block that looks like:

```typescript
            {!isSharedView && (
              <>
                <button
                  onClick={handleGenerate}
```

Inside the `<>...</>` fragment that wraps the non-shared-view buttons, add `<ShareButton />` as the last item before the closing `</>`:

```typescript
                <ShareButton />
```

- [ ] **Step 3: Build to verify**

```bash
npm run build
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/pages/GeneratePage.tsx
git commit -m "feat: add cloud Share button to GeneratePage"
```

---

### Task 8: SharedSessionPage

**Files:**
- Create: `src/pages/SharedSessionPage.tsx`

- [ ] **Step 1: Create the file**

```typescript
// src/pages/SharedSessionPage.tsx
import { useState, useEffect, useCallback } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { getSession, publishSession, type CloudSnapshot } from '../utils/cloudSync'
import type { GeneratorResult } from '../generator'
import type { GameScore } from '../store'

// Lazy import of SummaryModal — it lives inside GeneratePage.tsx which is a large file.
// We re-export it by wrapping the props interface here.
// Because SummaryModal is not exported from GeneratePage, we duplicate a thin wrapper
// using the exported types and render it via a dynamic import approach.
// Simpler: just import GeneratePage internals by moving SummaryModal to its own file.
// For now, inline a minimal shared summary view that mirrors SummaryModal behaviour.

import { useStore } from '../store'

// We need SummaryModal — move it out of GeneratePage into its own file first.
// See Task 8 Step 0 below.
import SummaryModal from '../components/SummaryModal'

export default function SharedSessionPage() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const navigate = useNavigate()

  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [snapshot, setSnapshot] = useState<CloudSnapshot | null>(null)
  const [playedGames, setPlayedGames] = useState<string[]>([])
  const [gameScores, setGameScores] = useState<Record<string, GameScore>>({})

  const fetchSession = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const data = await getSession(sessionId!)
      if (!data) { setError('Session not found.'); return }
      setSnapshot(data)
      setPlayedGames(data.playedGames)
      setGameScores(data.gameScores)
    } catch {
      setError('Failed to load session. Check your connection.')
    } finally {
      setLoading(false)
    }
  }, [sessionId])

  useEffect(() => { fetchSession() }, [fetchSession])

  async function handleTogglePlayed(key: string) {
    if (!snapshot) return
    const next = playedGames.includes(key)
      ? playedGames.filter((k) => k !== key)
      : [...playedGames, key]
    setPlayedGames(next)
    const updated: CloudSnapshot = { ...snapshot, playedGames: next, gameScores }
    setSnapshot(updated)
    try { await publishSession(sessionId!, updated) } catch { /* silent — local state updated */ }
  }

  async function handleSetScore(key: string, a: number, b: number) {
    if (!snapshot) return
    const nextScores = { ...gameScores, [key]: { a, b } }
    setGameScores(nextScores)
    const updated: CloudSnapshot = { ...snapshot, playedGames, gameScores: nextScores }
    setSnapshot(updated)
    try { await publishSession(sessionId!, updated) } catch { /* silent */ }
  }

  if (loading) {
    return (
      <div className="fixed inset-0 bg-slate-950 flex items-center justify-center">
        <span className="text-slate-400 text-sm">Loading session…</span>
      </div>
    )
  }

  if (error || !snapshot) {
    return (
      <div className="fixed inset-0 bg-slate-950 flex flex-col items-center justify-center gap-4">
        <span className="text-slate-300 text-sm">{error ?? 'Session not found.'}</span>
        <button
          onClick={() => navigate('/')}
          className="text-xs text-indigo-400 hover:text-white underline underline-offset-2"
        >
          Go to home
        </button>
      </div>
    )
  }

  const playerMap = new Map(snapshot.players.map((p) => [p.id, p]))

  const result: GeneratorResult = {
    schedule: snapshot.schedule,
    playCount: {},
    sitCount: {},
    partnerWith: {},
    facedBy: {},
    unplacedFixMatches: [],
  }

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
      onRefresh={fetchSession}
    />
  )
}
```

**Important:** `SharedSessionPage` imports `SummaryModal` from `../components/SummaryModal`, but currently `SummaryModal` is defined inside `GeneratePage.tsx`. Before this file works, the function must be extracted.

- [ ] **Step 0 (before Step 1): Extract SummaryModal into its own file**

Move the `SummaryModal` function and its local helpers (`StandingsTab`, `ordinal`) from `src/pages/GeneratePage.tsx` into a new file `src/components/SummaryModal.tsx`. Export `SummaryModal` as the default export. `StandingsTab` and `ordinal` stay private (not exported) in that file.

After moving:
- Add to `src/components/SummaryModal.tsx` these imports it needs:
  ```typescript
  import { useState } from 'react'
  import type { GeneratorResult } from '../generator'
  import type { Player, GameScore } from '../store'
  import { computeStandings } from '../utils/standings'
  ```
- In `src/pages/GeneratePage.tsx`, replace the moved code with:
  ```typescript
  import SummaryModal from '../components/SummaryModal'
  ```

- [ ] **Step 2: Build to verify no TypeScript errors**

```bash
npm run build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/components/SummaryModal.tsx src/pages/GeneratePage.tsx src/pages/SharedSessionPage.tsx
git commit -m "feat: extract SummaryModal component and add SharedSessionPage"
```

---

### Task 9: Register /s/:sessionId route

**Files:**
- Modify: `src/App.tsx`

- [ ] **Step 1: Import SharedSessionPage**

At the top of `src/App.tsx`, add:
```typescript
import SharedSessionPage from './pages/SharedSessionPage'
```

- [ ] **Step 2: Add the route outside the Layout wrapper**

Find:
```typescript
      <BrowserRouter>
        <Routes>
          <Route element={<Layout />}>
            <Route index element={<SetupPage />} />
            <Route path="players" element={<RequireSession><PlayersPage /></RequireSession>} />
            <Route path="constraints" element={<RequirePlayers><ConstraintsPage /></RequirePlayers>} />
            <Route path="generate" element={<RequirePlayers><GeneratePage /></RequirePlayers>} />
            <Route path="view" element={<SharedViewPage />} />
          </Route>
        </Routes>
      </BrowserRouter>
```

Replace with:
```typescript
      <BrowserRouter>
        <Routes>
          <Route element={<Layout />}>
            <Route index element={<SetupPage />} />
            <Route path="players" element={<RequireSession><PlayersPage /></RequireSession>} />
            <Route path="constraints" element={<RequirePlayers><ConstraintsPage /></RequirePlayers>} />
            <Route path="generate" element={<RequirePlayers><GeneratePage /></RequirePlayers>} />
            <Route path="view" element={<SharedViewPage />} />
          </Route>
          <Route path="s/:sessionId" element={<SharedSessionPage />} />
        </Routes>
      </BrowserRouter>
```

- [ ] **Step 3: Final build verification**

```bash
npm run build
```

Expected: build succeeds with zero TypeScript errors.

- [ ] **Step 4: Commit**

```bash
git add src/App.tsx
git commit -m "feat: register /s/:sessionId route for shared sessions"
```

---

### Task 10: Manual setup instructions

No code. Document what the developer must do in Google Drive after the code is merged.

- [ ] **Step 1: Create the Google Sheet**

1. Go to [sheets.google.com](https://sheets.google.com) and create a new spreadsheet named `Badminton Sessions`.
2. The first tab can be named anything — the Apps Script creates a `Sessions` tab automatically on first write.

- [ ] **Step 2: Deploy the Apps Script**

1. In the spreadsheet, go to **Extensions → Apps Script**.
2. Delete the default `function myFunction() {}`.
3. Paste the contents of `apps-script/Code.gs`.
4. Click **Deploy → New deployment**.
5. Type: **Web app**.
6. Execute as: **Me**.
7. Who has access: **Anyone**.
8. Click **Deploy** and copy the deployment URL.

- [ ] **Step 3: Set the environment variable**

For local dev, create `.env.local` (already in `.gitignore`):
```
VITE_APPS_SCRIPT_URL=https://script.google.com/macros/s/YOUR_ID/exec
```

For Vercel, go to project **Settings → Environment Variables** and add `VITE_APPS_SCRIPT_URL` with the same URL.

- [ ] **Step 4: Redeploy on Vercel**

Trigger a new Vercel deployment so the env var is baked into the build (Vite embeds it at build time).

---

## Self-Review

**Spec coverage:**
- ✅ Short URL (`/s/:sessionId`) — Task 9
- ✅ GET session from Apps Script — Task 3 (`getSession`)
- ✅ POST session to Apps Script — Task 3 (`publishSession`)
- ✅ Apps Script reads/writes Google Sheet — Task 1
- ✅ `cloudSessionId` in store — Task 4
- ✅ Share button in GeneratePage — Tasks 6 + 7
- ✅ SharedSessionPage — Task 8
- ✅ Refresh button in SummaryModal — Task 5 (onRefresh prop)
- ✅ Loading and error states — Task 8
- ✅ Score + checklist write-back — Task 8 handlers
- ✅ Manual deploy instructions — Task 10
- ✅ `VITE_APPS_SCRIPT_URL` env var — Task 2

**Type consistency:**
- `CloudSnapshot` defined in Task 3, used in Tasks 6 + 8 ✅
- `SummaryModal` props (`playedGames`, `gameScores`, `onTogglePlayedGame`, `onSetGameScore`, `onRefresh`) defined in Task 5, consumed in Tasks 7 + 8 ✅
- `GeneratorResult` minimal stub in Task 8 matches type from `src/generator/index.ts` ✅

**Note on Task 8 Step 0:** Extracting `SummaryModal` to its own file is a prerequisite for `SharedSessionPage`. Task 8 includes this extraction as Step 0 to keep it co-located with the work that requires it.
