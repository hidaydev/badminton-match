# Standings Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add "Standing Post" and "Standing Story" export options to the Instagram Post page's download sheet, rendering a top-10 leaderboard from a user-selected cloud session.

**Architecture:** All changes live in `src/pages/InstagramPostPage.tsx` plus a new `useFetchSession` imperative helper in `src/queries/sessions.ts`. The download sheet grows a second screen (session picker) activated when a standing option is tapped. Canvas rendering is handled by a new `drawStandingsCanvas()` function that draws rank/name/W·L/diff rows with fixed-width column alignment.

**Tech Stack:** React 19, HTML5 Canvas 2D, @tanstack/react-query v5, existing `computeStandings()` util, existing overlay assets (story-bg, logo, footer).

---

## File Map

| File | Change |
|------|--------|
| `src/queries/sessions.ts` | Add `useFetchSession()` imperative fetch hook |
| `src/queries/index.ts` | Already re-exports everything from sessions via `export *` — no change needed |
| `src/pages/InstagramPostPage.tsx` | Add state, session picker UI, `drawStandingsCanvas()`, two download handlers |

---

### Task 1: Add `useFetchSession` to queries layer

**Files:**
- Modify: `src/queries/sessions.ts`

- [ ] **Step 1: Add hook** — append to the bottom of `src/queries/sessions.ts`:

```ts
export function useFetchSession() {
  const queryClient = useQueryClient()
  return useCallback(
    (id: string) =>
      queryClient.fetchQuery<CloudSnapshot | null>({
        queryKey: ['session', id],
        queryFn: () => getSession(id),
      }),
    [queryClient],
  )
}
```

Add `useCallback` to the existing import at line 1:
```ts
import { useQuery, useMutation, useQueryClient, useCallback } from '@tanstack/react-query'
```

- [ ] **Step 2: Verify build**

```bash
npm run build 2>&1 | tail -20
```
Expected: no TypeScript errors.

- [ ] **Step 3: Commit**

```bash
git add src/queries/sessions.ts
git commit -m "feat: add useFetchSession imperative helper to queries layer"
```

---

### Task 2: Add new state + import hooks in InstagramPostPage

**Files:**
- Modify: `src/pages/InstagramPostPage.tsx`

- [ ] **Step 1: Add imports at top of file** — replace the existing import block:

```ts
import { useRef, useState, useEffect, useCallback, useMemo } from 'react'
import { useNavigate } from 'react-router-dom'
import { instagramTemplates, type PostTemplate } from '../config/instagramTemplates'
import { useListSessions, useFetchSession } from '../queries'
import { computeStandings, type PlayerStanding } from '../utils/standings'
import type { SessionMeta } from '../queries'
```

- [ ] **Step 2: Add new state inside the component** — after the existing `const [showDownloadSheet, setShowDownloadSheet] = useState(false)` line, add:

```ts
type StandingMode = 'post' | 'story'
const [sheetScreen, setSheetScreen] = useState<'formats' | 'session-picker'>('formats')
const [pendingStandingMode, setPendingStandingMode] = useState<StandingMode | null>(null)
const [isGenerating, setIsGenerating] = useState(false)
const { data: sessions } = useListSessions()
const fetchSession = useFetchSession()
```

- [ ] **Step 3: Reset sheetScreen when sheet closes** — update the `setShowDownloadSheet(false)` helper so it also resets the inner screen. Add a helper near the download handlers:

```ts
const closeSheet = useCallback(() => {
  setShowDownloadSheet(false)
  setSheetScreen('formats')
  setPendingStandingMode(null)
  setIsGenerating(false)
}, [])
```

Replace all `setShowDownloadSheet(false)` calls in `handleDownloadPost` and `handleDownloadStory` with `closeSheet()`.

Also replace the backdrop `onClick={() => setShowDownloadSheet(false)}` with `onClick={closeSheet}`.

- [ ] **Step 4: Verify build**

```bash
npm run build 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```bash
git add src/pages/InstagramPostPage.tsx
git commit -m "feat: add standing export state and session fetch hook to InstagramPostPage"
```

---

### Task 3: Update download sheet to 2×2 grid + session picker screen

**Files:**
- Modify: `src/pages/InstagramPostPage.tsx`

- [ ] **Step 1: Replace the download sheet JSX** — replace the entire `{showDownloadSheet && (...)}` block with:

```tsx
{showDownloadSheet && (
  <div
    className="fixed inset-0 z-50 flex items-end"
    onClick={closeSheet}
  >
    <div className="absolute inset-0 bg-black/60" />
    <div
      className="relative w-full bg-slate-900 rounded-t-3xl px-5 pt-5 pb-10 shadow-[0_-8px_40px_rgba(0,0,0,0.6)]"
      onClick={e => e.stopPropagation()}
    >
      <div className="w-10 h-1 bg-slate-700 rounded-full mx-auto mb-6" />

      {sheetScreen === 'formats' && (
        <>
          <p className="text-xs font-mono text-slate-500 tracking-widest uppercase mb-4">Download as</p>
          <div className="grid grid-cols-2 gap-3">
            {/* Photo Post */}
            <button
              onClick={handleDownloadPost}
              className="bg-slate-800 active:bg-slate-700 rounded-2xl p-4 flex flex-col items-center gap-3 border border-slate-700"
            >
              <div className="w-12 h-[60px] rounded-lg bg-slate-700 border border-slate-600" />
              <div className="text-center">
                <p className="text-sm font-bold text-white">Post</p>
                <p className="text-[11px] text-slate-500">1080 × 1350</p>
              </div>
            </button>

            {/* Photo Story */}
            <button
              onClick={handleDownloadStory}
              className="bg-yellow-400 active:bg-yellow-300 rounded-2xl p-4 flex flex-col items-center gap-3"
            >
              <div className="w-12 h-[60px] rounded-lg bg-yellow-300 border border-yellow-500 flex items-center justify-center">
                <div className="w-7 h-7 rounded bg-yellow-500/40" />
              </div>
              <div className="text-center">
                <p className="text-sm font-bold text-black">Story</p>
                <p className="text-[11px] text-yellow-800">1080 × 1920</p>
              </div>
            </button>

            {/* Standing Post */}
            <button
              onClick={() => { setPendingStandingMode('post'); setSheetScreen('session-picker') }}
              className="bg-slate-800 active:bg-slate-700 rounded-2xl p-4 flex flex-col items-center gap-3 border border-slate-700"
            >
              <div className="w-12 h-[60px] rounded-lg bg-slate-700 border border-slate-600 flex items-center justify-center">
                <span className="text-lg">🏆</span>
              </div>
              <div className="text-center">
                <p className="text-sm font-bold text-white">Standing Post</p>
                <p className="text-[11px] text-slate-500">1080 × 1350</p>
              </div>
            </button>

            {/* Standing Story */}
            <button
              onClick={() => { setPendingStandingMode('story'); setSheetScreen('session-picker') }}
              className="bg-yellow-400 active:bg-yellow-300 rounded-2xl p-4 flex flex-col items-center gap-3"
            >
              <div className="w-12 h-[60px] rounded-lg bg-yellow-300 border border-yellow-500 flex items-center justify-center">
                <span className="text-lg">🏆</span>
              </div>
              <div className="text-center">
                <p className="text-sm font-bold text-black">Standing Story</p>
                <p className="text-[11px] text-yellow-800">1080 × 1920</p>
              </div>
            </button>
          </div>
        </>
      )}

      {sheetScreen === 'session-picker' && (
        <>
          <div className="flex items-center gap-3 mb-4">
            <button
              onClick={() => { setSheetScreen('formats'); setIsGenerating(false) }}
              className="w-8 h-8 rounded-full bg-slate-800 flex items-center justify-center text-slate-400 text-sm active:bg-slate-700"
            >
              ←
            </button>
            <p className="text-xs font-mono text-slate-500 tracking-widest uppercase">Pick a session</p>
          </div>

          {isGenerating && (
            <div className="flex items-center justify-center py-8 gap-3">
              <div className="w-5 h-5 rounded-full border-2 border-yellow-400 border-t-transparent animate-spin" />
              <span className="text-sm text-slate-400">Generating…</span>
            </div>
          )}

          {!isGenerating && (
            <div className="flex flex-col gap-2 max-h-72 overflow-y-auto">
              {(sessions ?? []).map(s => (
                <button
                  key={s.id}
                  onClick={() => handleDownloadStanding(s)}
                  className="flex items-center gap-3 px-4 py-3 rounded-2xl bg-slate-800 active:bg-slate-700 border border-slate-700 text-left"
                >
                  <div className="flex-1 min-w-0">
                    <p className="text-sm font-semibold text-white truncate">{s.title}</p>
                    <p className="text-[11px] text-slate-500">{s.date} · {s.playerCount} players</p>
                  </div>
                  <span className="text-slate-600 text-xs">→</span>
                </button>
              ))}
              {!sessions && (
                <p className="text-sm text-slate-500 text-center py-4">Loading sessions…</p>
              )}
              {sessions?.length === 0 && (
                <p className="text-sm text-slate-500 text-center py-4">No sessions found</p>
              )}
            </div>
          )}
        </>
      )}
    </div>
  </div>
)}
```

- [ ] **Step 2: Verify build**

```bash
npm run build 2>&1 | tail -20
```
Expected: error on `handleDownloadStanding` (not defined yet — that's fine, add a stub):
```ts
const handleDownloadStanding = useCallback((_s: SessionMeta) => {}, [])
```

- [ ] **Step 3: Commit**

```bash
git add src/pages/InstagramPostPage.tsx
git commit -m "feat: update download sheet to 2x2 grid with session picker screen"
```

---

### Task 4: Implement `drawStandingsCanvas()`

**Files:**
- Modify: `src/pages/InstagramPostPage.tsx`

Add this function in the module scope (alongside the existing `drawCanvas`, `drawHeader`, etc. functions):

- [ ] **Step 1: Add the function** — insert after the closing `}` of `drawCanvas`:

```ts
function drawStandingsCanvas(
  canvas: HTMLCanvasElement,
  standings: PlayerStanding[],
  meta: { date: string; title: string; playerCount: number },
  overlays: { logo?: HTMLImageElement; footer?: HTMLImageElement; storyBg?: HTMLImageElement },
  isStory: boolean,
) {
  const ctx = canvas.getContext('2d')!
  const W = canvas.width   // always 1080
  const H = canvas.height  // 1350 (post) or 1920 (story)

  ctx.clearRect(0, 0, W, H)

  // Background
  if (isStory && overlays.storyBg) {
    ctx.drawImage(overlays.storyBg, 0, 0, W, H)
  } else {
    ctx.fillStyle = '#1e293b'
    ctx.fillRect(0, 0, W, H)
  }

  // Header
  drawHeader(ctx, W, overlays.logo)

  // Footer
  const FOOTER_H = overlays.footer
    ? W * (overlays.footer.naturalHeight / overlays.footer.naturalWidth)
    : 120
  if (overlays.footer) {
    ctx.drawImage(overlays.footer, 0, H - FOOTER_H, W, FOOTER_H)
  }

  // Content area bounds
  const HEADER_H_PX = 90
  const CONTENT_TOP = HEADER_H_PX + 30
  const CONTENT_BOT = H - FOOTER_H - 30
  const CONTENT_H = CONTENT_BOT - CONTENT_TOP

  // Dark card for story
  if (isStory) {
    const cardPadX = 50
    const cardPadY = 40
    ctx.save()
    ctx.fillStyle = 'rgba(15, 23, 42, 0.88)'
    const cardX = cardPadX
    const cardY = CONTENT_TOP + cardPadY
    const cardW = W - cardPadX * 2
    const cardH = CONTENT_H - cardPadY * 2
    ctx.beginPath()
    ctx.roundRect(cardX, cardY, cardW, cardH, 24)
    ctx.fill()
    ctx.restore()
  }

  const innerTop = isStory ? CONTENT_TOP + 100 : CONTENT_TOP + 40
  const innerPadX = isStory ? 100 : 60

  // Session meta line
  ctx.save()
  ctx.font = '28px monospace'
  ctx.fillStyle = '#94a3b8'
  ctx.textAlign = 'left'
  ctx.fillText(`${meta.date}  ·  ${meta.title}`, innerPadX, innerTop)
  ctx.restore()

  // Title
  ctx.save()
  ctx.font = 'bold 46px Arial, sans-serif'
  ctx.fillStyle = '#facc15'
  ctx.textAlign = 'left'
  ctx.fillText(`TOP 10 OF ${meta.playerCount} PLAYERS`, innerPadX, innerTop + 70)
  ctx.restore()

  // Rows
  const top10 = standings.slice(0, 10)
  const rowsTop = innerTop + 120
  const rowsAvailable = (isStory ? CONTENT_BOT - 80 : CONTENT_BOT) - rowsTop - 20
  const rowH = Math.floor(rowsAvailable / 10)

  // Fixed column x positions
  const RANK_CX = innerPadX + 30           // center of rank/medal
  const NAME_X = innerPadX + 90            // left edge of name
  const W_RIGHT_X = W - innerPadX - 290    // right-align W count
  const SEP_CX = W - innerPadX - 265       // center of ·
  const L_LEFT_X = W - innerPadX - 250     // left-align L count
  const DIFF_RIGHT_X = W - innerPadX       // right-align diff

  const MEDALS = ['🥇', '🥈', '🥉']
  const ROW_FONT_SIZE = Math.min(38, rowH * 0.48)
  const STATS_FONT_SIZE = Math.min(34, rowH * 0.43)

  for (let i = 0; i < top10.length; i++) {
    const s = top10[i]
    const rowY = rowsTop + i * rowH
    const baseline = rowY + rowH * 0.62

    // Separator line
    if (i > 0) {
      ctx.save()
      ctx.strokeStyle = 'rgba(255,255,255,0.06)'
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(innerPadX, rowY)
      ctx.lineTo(W - innerPadX, rowY)
      ctx.stroke()
      ctx.restore()
    }

    // Rank / medal
    ctx.save()
    if (i < 3) {
      ctx.font = `${ROW_FONT_SIZE}px Arial`
      ctx.textAlign = 'center'
      ctx.fillText(MEDALS[i], RANK_CX, baseline)
    } else {
      ctx.font = `bold ${ROW_FONT_SIZE * 0.75}px monospace`
      ctx.fillStyle = '#475569'
      ctx.textAlign = 'center'
      ctx.fillText(String(i + 1), RANK_CX, baseline)
    }
    ctx.restore()

    // Name
    ctx.save()
    ctx.font = `bold ${ROW_FONT_SIZE}px Arial, sans-serif`
    ctx.fillStyle = '#ffffff'
    ctx.textAlign = 'left'
    // Clip name to avoid overlapping stats
    const maxNameW = W_RIGHT_X - NAME_X - 40
    let name = s.player.name
    while (ctx.measureText(name).width > maxNameW && name.length > 1) {
      name = name.slice(0, -1)
    }
    if (name !== s.player.name) name += '…'
    ctx.fillText(name, NAME_X, baseline)
    ctx.restore()

    // W count
    ctx.save()
    ctx.font = `bold ${STATS_FONT_SIZE}px monospace`
    ctx.fillStyle = '#facc15'
    ctx.textAlign = 'right'
    ctx.fillText(`${s.wins}W`, W_RIGHT_X, baseline)
    ctx.restore()

    // Separator ·
    ctx.save()
    ctx.font = `${STATS_FONT_SIZE}px monospace`
    ctx.fillStyle = '#334155'
    ctx.textAlign = 'center'
    ctx.fillText('·', SEP_CX, baseline)
    ctx.restore()

    // L count
    ctx.save()
    ctx.font = `bold ${STATS_FONT_SIZE}px monospace`
    ctx.fillStyle = '#475569'
    ctx.textAlign = 'left'
    ctx.fillText(`${s.losses}L`, L_LEFT_X, baseline)
    ctx.restore()

    // Diff
    const diff = s.diff
    ctx.save()
    ctx.font = `bold ${STATS_FONT_SIZE}px monospace`
    ctx.fillStyle = diff > 0 ? '#4ade80' : diff < 0 ? '#f87171' : '#475569'
    ctx.textAlign = 'right'
    ctx.fillText(diff > 0 ? `+${diff}` : String(diff), DIFF_RIGHT_X, baseline)
    ctx.restore()
  }
}
```

- [ ] **Step 2: Verify build**

```bash
npm run build 2>&1 | tail -20
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add src/pages/InstagramPostPage.tsx
git commit -m "feat: add drawStandingsCanvas function with fixed-column alignment"
```

---

### Task 5: Implement `handleDownloadStanding`

**Files:**
- Modify: `src/pages/InstagramPostPage.tsx`

- [ ] **Step 1: Replace the stub with the real handler** — find the stub `const handleDownloadStanding = useCallback((_s: SessionMeta) => {}, [])` and replace it with:

```ts
const handleDownloadStanding = useCallback(async (sessionMeta: SessionMeta) => {
  if (!pendingStandingMode) return
  const mode = pendingStandingMode
  setIsGenerating(true)

  try {
    const snapshot = await fetchSession(sessionMeta.id)
    if (!snapshot) return

    const standings = computeStandings(
      snapshot.players,
      snapshot.schedule,
      snapshot.gameScores,
    )

    const isStory = mode === 'story'
    const W = 1080
    const H = isStory ? 1920 : 1350

    const offscreen = document.createElement('canvas')
    offscreen.width = W
    offscreen.height = H

    drawStandingsCanvas(offscreen, standings, {
      date: sessionMeta.date,
      title: sessionMeta.title,
      playerCount: sessionMeta.playerCount,
    }, overlays, isStory)

    offscreen.toBlob((blob) => {
      if (!blob) return
      const slug = sessionMeta.date.replace(/-/g, '')
      triggerDownload(blob, `majadu-standing-${isStory ? 'story' : 'post'}-${slug}.jpg`)
    }, 'image/jpeg', 0.92)

    closeSheet()
  } catch (err) {
    console.error('Standing export failed', err)
    setIsGenerating(false)
  }
}, [pendingStandingMode, fetchSession, overlays, triggerDownload, closeSheet])
```

- [ ] **Step 2: Verify build**

```bash
npm run build 2>&1 | tail -20
```
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add src/pages/InstagramPostPage.tsx
git commit -m "feat: implement standing post and story download handlers"
```

---

### Task 6: Manual verification

No test suite exists. Verify in the browser:

- [ ] **Step 1: Start dev server**

```bash
npm run dev
```

- [ ] **Step 2: Check the download sheet** — open the app → Instagram Post page → upload any photo → tap the download button. Verify the sheet shows a 2×2 grid with Post, Story, Standing Post, Standing Story.

- [ ] **Step 3: Check session picker** — tap "Standing Post". Verify the sheet transitions to the session list with a back button.

- [ ] **Step 4: Download a standing post** — pick a session that has game scores recorded. Verify the file downloads as `majadu-standing-post-YYYYMMDD.jpg`.

- [ ] **Step 5: Open the downloaded image** — verify: dark background, header band with logo, top-10 list with medals for top 3, W·L aligned in monospace columns, colored diffs, footer PNG at bottom.

- [ ] **Step 6: Download a standing story** — repeat for "Standing Story". Verify: yellow story-bg, dark card overlay, same standings layout inside the card, 1080×1920 dimensions.

- [ ] **Step 7: Check back button** — verify tapping ← in session picker returns to the 2×2 format grid.

- [ ] **Step 8: Check close behavior** — verify tapping the backdrop or completing a download resets the sheet to the formats screen for next open.

- [ ] **Final commit** (if any small fixes were made during verification)

```bash
git add src/pages/InstagramPostPage.tsx src/queries/sessions.ts
git commit -m "fix: standings export verification fixes"
```
