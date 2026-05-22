# Group Match Post Generator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-group post generation to the tournament Groups tab — users upload photos per match and download Instagram-ready match posts (1080×1350 with score overlay) plus a group summary standings card.

**Architecture:** Extract shared canvas utilities into `src/utils/canvasPost.ts`, add post mode toggle UI to each group card in `GroupMatches.tsx`, implement two canvas draw functions (match post + group summary) inside the component, and trigger sequential blob downloads on tap.

**Tech Stack:** React 19, TypeScript, HTML5 Canvas (no extra libs), Tailwind v4, existing `instagramTemplates` config for asset paths.

> **Note:** No test suite exists. Verify each task by running `npm run dev` and checking in browser.

---

### Task 1: Extract shared canvas utilities to `src/utils/canvasPost.ts`

**Files:**
- Create: `src/utils/canvasPost.ts`
- Modify: `src/pages/InstagramPostPage.tsx` (import from shared module, remove local definitions)

- [ ] **Step 1: Create `src/utils/canvasPost.ts`**

Copy these three functions verbatim from `src/pages/InstagramPostPage.tsx` (lines 15–98):

```typescript
// src/utils/canvasPost.ts

const HEADER_H = 90
const LOGO_H = 28

export function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.onload = () => resolve(img)
    img.onerror = reject
    img.src = src
  })
}

export function drawCoverFill(
  ctx: CanvasRenderingContext2D,
  img: HTMLImageElement,
  canvasW: number,
  canvasH: number,
  offsetX: number,
  offsetY: number,
  zoom: number = 1,
) {
  const scale = Math.max(canvasW / img.naturalWidth, canvasH / img.naturalHeight) * zoom
  const w = img.naturalWidth * scale
  const h = img.naturalHeight * scale
  const x = (canvasW - w) / 2 + offsetX
  const y = (canvasH - h) / 2 + offsetY
  ctx.drawImage(img, x, y, w, h)
}

function drawSideText(
  ctx: CanvasRenderingContext2D,
  startX: number,
  y: number,
  fontSize: number,
) {
  const segments = [
    { text: 'MAJADU FUN', color: '#ffffff' },
    { text: '  •  ', color: '#facc15' },
    { text: 'MAJADU FUN', color: '#ffffff' },
    { text: '  •  ', color: '#facc15' },
    { text: 'MAJADU FUN', color: '#ffffff' },
  ]
  ctx.font = `bold ${fontSize}px Arial, sans-serif`
  ctx.letterSpacing = '1.5px'
  let x = startX
  for (const seg of segments) {
    ctx.fillStyle = seg.color
    ctx.textAlign = 'left'
    ctx.fillText(seg.text, x, y)
    x += ctx.measureText(seg.text).width
  }
}

export function drawHeader(
  ctx: CanvasRenderingContext2D,
  canvasW: number,
  logo: HTMLImageElement | undefined,
) {
  const grad = ctx.createLinearGradient(0, 0, 0, HEADER_H)
  grad.addColorStop(0, 'rgba(10,10,20,0.92)')
  grad.addColorStop(1, 'rgba(0,0,0,0)')
  ctx.fillStyle = grad
  ctx.fillRect(0, 0, canvasW, HEADER_H)

  const fontSize = 15
  const logoW = logo ? LOGO_H * (logo.naturalWidth / logo.naturalHeight) : 160
  const centerPad = 30
  const sideZoneW = (canvasW - logoW) / 2 - centerPad
  const logoTop = (HEADER_H - LOGO_H) / 2
  const textY = HEADER_H / 2 + fontSize * 0.38

  ctx.font = `bold ${fontSize}px Arial, sans-serif`
  ctx.letterSpacing = '1.5px'
  const fullText = 'MAJADU FUN  •  MAJADU FUN  •  MAJADU FUN'
  const totalW = ctx.measureText(fullText).width
  const clampedW = Math.min(totalW, sideZoneW)

  const leftStartX = (canvasW - logoW) / 2 - centerPad - clampedW
  drawSideText(ctx, leftStartX, textY, fontSize)

  const rightStartX = (canvasW + logoW) / 2 + centerPad
  drawSideText(ctx, rightStartX, textY, fontSize)

  if (logo) {
    ctx.drawImage(logo, (canvasW - logoW) / 2, logoTop, logoW, LOGO_H)
  }
}
```

- [ ] **Step 2: Update `InstagramPostPage.tsx` to import from shared module**

At the top of `src/pages/InstagramPostPage.tsx`, replace the three local function definitions with imports:

```typescript
import { loadImage, drawCoverFill, drawHeader } from '../utils/canvasPost'
```

Then delete the `loadImage`, `drawCoverFill`, `drawSideText`, and `drawHeader` function bodies from `InstagramPostPage.tsx` (they're now in the shared module). The `HEADER_H` and `LOGO_H` constants stay in `canvasPost.ts`; remove them from `InstagramPostPage.tsx`.

- [ ] **Step 3: Verify build passes**

```bash
npm run build
```

Expected: no TypeScript errors. If there are missing references to `HEADER_H` inside `InstagramPostPage.tsx`, check — the constant is only used inside `drawHeader` and `drawStandingsCanvas`. `drawStandingsCanvas` stays local to `InstagramPostPage.tsx` and uses a local `HEADER_H_PX = 90` copy (already named differently inside that function — see line 272).

- [ ] **Step 4: Run dev server and spot-check Instagram Post page still works**

```bash
npm run dev
```

Navigate to Instagram Post page, upload a photo, confirm the header renders. Then close the dev server.

- [ ] **Step 5: Commit**

```bash
git add src/utils/canvasPost.ts src/pages/InstagramPostPage.tsx
git commit -m "refactor: extract drawCoverFill, drawHeader, loadImage to shared canvasPost util"
```

---

### Task 2: Add post mode state and toggle button to each group card

**Files:**
- Modify: `src/components/tournament/GroupMatches.tsx`

- [ ] **Step 1: Add per-group post mode state inside the `GROUP_IDS.map` render**

In `GroupMatches.tsx`, the component currently has a single `useState` for `activeMatchId`. Add two new state items at the top of the component (before the return):

```typescript
const [postModeGroups, setPostModeGroups] = useState<Record<string, boolean>>({})
const [matchPhotos, setMatchPhotos] = useState<Record<string, HTMLImageElement>>({})
```

- [ ] **Step 2: Add the camera toggle button to each group header**

Find the group header JSX (currently renders `GROUP {g}` label and `Court {GROUP_COURTS[g]}`):

```tsx
<div className="px-4 py-2 flex justify-between items-center border-b border-yellow-500/30">
  <span className="text-yellow-300 font-bold text-sm">GROUP {g}</span>
  <span className="text-yellow-600 text-xs">Court {GROUP_COURTS[g]}</span>
</div>
```

Replace with:

```tsx
<div className="px-4 py-2 flex justify-between items-center border-b border-yellow-500/30">
  <span className="text-yellow-300 font-bold text-sm">GROUP {g}</span>
  <div className="flex items-center gap-3">
    <span className="text-yellow-600 text-xs">Court {GROUP_COURTS[g]}</span>
    <button
      onClick={() => setPostModeGroups(prev => ({ ...prev, [g]: !prev[g] }))}
      className={`w-8 h-8 rounded-full flex items-center justify-center transition-colors ${
        postModeGroups[g] ? 'bg-yellow-400 active:bg-yellow-300' : 'bg-black/50 active:bg-black/70'
      }`}
    >
      <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke={postModeGroups[g] ? 'black' : 'white'} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
        <circle cx="12" cy="13" r="4"/>
      </svg>
    </button>
  </div>
</div>
```

- [ ] **Step 3: Verify in browser**

```bash
npm run dev
```

Navigate to Tournament → Groups (lock a group assignment first if needed). Tap the camera icon in a group header — it should turn yellow. Tap again — turns dark. No other UI changes yet.

- [ ] **Step 4: Commit**

```bash
git add src/components/tournament/GroupMatches.tsx
git commit -m "feat: add post mode toggle button to group card headers"
```

---

### Task 3: Add per-match photo upload buttons and download bar

**Files:**
- Modify: `src/components/tournament/GroupMatches.tsx`

- [ ] **Step 1: Add a hidden file input ref per group**

At the top of the `GroupMatches` component (alongside existing state), add:

```typescript
const fileInputRefs = useRef<Record<string, HTMLInputElement | null>>({})
const activeUploadMatchId = useRef<string | null>(null)
```

Import `useRef` if not already imported (check line 1 — it currently imports `useState` from react).

- [ ] **Step 2: Add the shared hidden file input element**

Inside the component's return JSX, just before the closing `</div>` of the outer `space-y-4` wrapper, add a single hidden file input (shared across all matches, reused via the `activeUploadMatchId` ref):

```tsx
<input
  type="file"
  accept="image/jpeg,image/png,image/webp"
  className="hidden"
  ref={el => { fileInputRefs.current['__shared__'] = el }}
  onChange={async (e) => {
    const file = e.target.files?.[0]
    const matchId = activeUploadMatchId.current
    if (!file || !matchId) return
    const url = URL.createObjectURL(file)
    const img = new Image()
    img.onload = () => {
      URL.revokeObjectURL(url)
      setMatchPhotos(prev => ({ ...prev, [matchId]: img }))
    }
    img.src = url
    e.target.value = ''
  }}
/>
```

- [ ] **Step 3: Add per-match camera button inside each match row**

Find the match row button JSX inside the `groupMatches.map`. It currently ends after the `picName` span. Add a camera upload button that only renders when `postModeGroups[g]` is true.

The existing match row is a `<button>` that opens the score modal. Wrap the row content and the new camera button in a relative container. Replace the existing match row:

```tsx
<div key={m.id} className="relative flex items-center">
  <button
    onClick={() => { onOpenModal(); setActiveMatchId(m.id) }}
    className="flex-1 flex flex-col px-4 pt-3 pb-2.5 hover:bg-slate-700/50 active:bg-slate-600/60 active:scale-[0.98] transition-transform duration-75 gap-1.5"
  >
    <div className="flex items-center gap-2 w-full">
      <span className="text-xs text-slate-300 flex-1 truncate text-left">{getPairName(m.pairAId)}</span>
      <span className="text-xs font-bold text-yellow-400 shrink-0 min-w-[56px] text-center bg-slate-900 rounded-md px-2 py-1">
        {m.scoreA !== null ? `${m.scoreA}–${m.scoreB}` : '—'}
      </span>
      <span className="text-xs text-slate-300 flex-1 text-right truncate">{getPairName(m.pairBId)}</span>
    </div>
    {m.picName && (
      <span className="text-[9px] text-slate-500 leading-none text-center w-full">{m.picName}</span>
    )}
  </button>

  {postModeGroups[g] && (
    <div className="relative pr-3 shrink-0">
      <button
        onClick={() => {
          activeUploadMatchId.current = m.id
          fileInputRefs.current['__shared__']?.click()
        }}
        className="w-7 h-7 rounded-full bg-black/50 flex items-center justify-center active:bg-black/70"
      >
        <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="white" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
          <circle cx="12" cy="13" r="4"/>
        </svg>
      </button>
      {matchPhotos[m.id] && (
        <span className="absolute -top-0.5 -right-0.5 w-2 h-2 rounded-full bg-green-500 border border-slate-800" />
      )}
    </div>
  )}
</div>
```

- [ ] **Step 4: Add download bar below the match rows for active post mode groups**

Inside the `GROUP_IDS.map`, after the closing `</div>` of the `divide-y divide-slate-700/50` match rows section, and before the mini standings `<div>`, add:

```tsx
{postModeGroups[g] && (
  <div className="border-t border-slate-700 px-4 py-2.5 flex items-center justify-between bg-slate-900/50">
    <span className="text-xs text-slate-500">
      {Object.keys(matchPhotos).filter(id => groupMatches.some(m => m.id === id)).length} of {groupMatches.length} photos
    </span>
    <button
      onClick={() => handleDownloadGroup(g, groupMatches, groups[g], matches)}
      className="w-8 h-8 rounded-full bg-yellow-400 flex items-center justify-center active:bg-yellow-300"
    >
      <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="black" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
        <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
        <polyline points="7 10 12 15 17 10"/>
        <line x1="12" y1="15" x2="12" y2="3"/>
      </svg>
    </button>
  </div>
)}
```

`handleDownloadGroup` will be defined in Task 4. For now, add a placeholder above the return statement so TypeScript doesn't error:

```typescript
const handleDownloadGroup = (_g: GroupId, _groupMatches: TournamentMatch[], _pairIds: string[], _allMatches: TournamentMatch[]) => {}
```

- [ ] **Step 5: Verify in browser**

```bash
npm run dev
```

Toggle post mode on a group → camera buttons appear on each row, download bar appears. Tap a camera button → file picker opens. Select a photo → green dot appears on that match's camera button. Photo count updates in download bar.

- [ ] **Step 6: Commit**

```bash
git add src/components/tournament/GroupMatches.tsx
git commit -m "feat: add per-match photo upload buttons and download bar to group post mode"
```

---

### Task 4: Implement canvas generation and batch download

**Files:**
- Modify: `src/components/tournament/GroupMatches.tsx`

- [ ] **Step 1: Load overlays (logo + storyBg) inside GroupMatches**

Add overlay state and a load effect at the top of the `GroupMatches` component, after existing state:

```typescript
const [overlays, setOverlays] = useState<{ logo?: HTMLImageElement; storyBg?: HTMLImageElement }>({})

useEffect(() => {
  const load = async () => {
    const result: { logo?: HTMLImageElement; storyBg?: HTMLImageElement } = {}
    try { result.logo = await loadImage('/instagram-logo.png') } catch { /* skip */ }
    try { result.storyBg = await loadImage('/story-bg.png') } catch { /* skip */ }
    setOverlays(result)
  }
  load()
}, [])
```

Add the import at the top of `GroupMatches.tsx`:

```typescript
import { loadImage, drawCoverFill, drawHeader } from '../../utils/canvasPost'
```

Also add `useEffect` to the React import if not already there.

- [ ] **Step 2: Implement `drawMatchPost` canvas function**

Add this function inside `GroupMatches.tsx`, above the component function:

```typescript
function drawMatchPost(
  canvas: HTMLCanvasElement,
  photo: HTMLImageElement,
  pairAName: string,
  pairBName: string,
  scoreA: number,
  scoreB: number,
  groupId: string,
  matchIndex: number,
  logo: HTMLImageElement | undefined,
) {
  const W = 1080
  const H = 1350
  canvas.width = W
  canvas.height = H
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, W, H)

  // Layer 1: photo
  drawCoverFill(ctx, photo, W, H, 0, 0, 1)

  // Layer 2: header
  drawHeader(ctx, W, logo)

  // Layer 3: score footer
  const footerH = 110
  const footerY = H - footerH
  ctx.save()
  ctx.fillStyle = 'rgba(0,0,0,0.75)'
  ctx.fillRect(0, footerY, W, footerH)
  ctx.restore()

  // Pair names + score
  const midY = footerY + 58
  ctx.save()
  ctx.font = 'bold 42px Arial, sans-serif'
  ctx.fillStyle = '#ffffff'
  ctx.textAlign = 'left'
  const maxNameW = 340
  let nameA = pairAName
  while (ctx.measureText(nameA).width > maxNameW && nameA.length > 1) nameA = nameA.slice(0, -1)
  if (nameA !== pairAName) nameA += '…'
  ctx.fillText(nameA, 60, midY)
  ctx.restore()

  ctx.save()
  ctx.font = 'bold 42px Arial, sans-serif'
  ctx.fillStyle = '#ffffff'
  ctx.textAlign = 'right'
  let nameB = pairBName
  while (ctx.measureText(nameB).width > maxNameW && nameB.length > 1) nameB = nameB.slice(0, -1)
  if (nameB !== pairBName) nameB += '…'
  ctx.fillText(nameB, W - 60, midY)
  ctx.restore()

  ctx.save()
  ctx.font = 'bold 52px monospace'
  ctx.fillStyle = '#facc15'
  ctx.textAlign = 'center'
  ctx.fillText(`${scoreA} – ${scoreB}`, W / 2, midY)
  ctx.restore()

  // Subtitle
  ctx.save()
  ctx.font = '26px monospace'
  ctx.fillStyle = '#64748b'
  ctx.textAlign = 'center'
  ctx.fillText(`GROUP ${groupId} · MATCH ${matchIndex}`, W / 2, footerY + 88)
  ctx.restore()
}
```

- [ ] **Step 3: Implement `drawGroupSummary` canvas function**

Add this function inside `GroupMatches.tsx`, just below `drawMatchPost`:

```typescript
function drawGroupSummary(
  canvas: HTMLCanvasElement,
  groupId: string,
  standings: import('../../utils/tournament').StandingRow[],
  getPairName: (id: string | null) => string,
  storyBg: HTMLImageElement | undefined,
) {
  const W = 1080
  const H = 1350
  canvas.width = W
  canvas.height = H
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, W, H)

  // Background
  if (storyBg) {
    ctx.drawImage(storyBg, 0, 0, W, H)
  } else {
    ctx.fillStyle = '#f59e0b'
    ctx.fillRect(0, 0, W, H)
  }

  // Dark card
  const CARD_X = 80
  const CARD_W = W - CARD_X * 2
  const ROW_H = 110
  const ROW_GAP = 10
  const CARD_PAD_TOP = 70
  const TITLE_H = 130
  const HDR_H = 50
  const CARD_PAD_BOT = 50
  const CARD_H = CARD_PAD_TOP + TITLE_H + HDR_H + standings.length * (ROW_H + ROW_GAP) + CARD_PAD_BOT
  const CARD_Y = (H - CARD_H) / 2

  ctx.save()
  ctx.fillStyle = 'rgba(4,7,14,0.94)'
  ctx.beginPath()
  ctx.roundRect(CARD_X, CARD_Y, CARD_W, CARD_H, 32)
  ctx.fill()
  ctx.restore()

  // Title
  const INNER_X = CARD_X + 60
  ctx.save()
  ctx.font = '28px monospace'
  ctx.fillStyle = '#64748b'
  ctx.letterSpacing = '4px'
  ctx.textAlign = 'left'
  ctx.fillText('FINAL STANDINGS', INNER_X, CARD_Y + CARD_PAD_TOP + 36)
  ctx.restore()

  ctx.save()
  ctx.font = 'bold 72px Arial, sans-serif'
  ctx.fillStyle = '#facc15'
  ctx.letterSpacing = '2px'
  ctx.textAlign = 'left'
  ctx.fillText(`GROUP ${groupId}`, INNER_X, CARD_Y + CARD_PAD_TOP + 120)
  ctx.restore()

  // Column header
  const HDR_Y = CARD_Y + CARD_PAD_TOP + TITLE_H + 30
  const COL_W = ctx.measureText('W').width
  void COL_W
  const RIGHT_X = CARD_X + CARD_W - 60
  const DIFF_X = RIGHT_X - 120
  const L_X = DIFF_X - 90
  const W_X = L_X - 90
  const DOT_X = RIGHT_X

  ctx.save()
  ctx.font = 'bold 26px monospace'
  ctx.fillStyle = '#475569'
  ctx.textAlign = 'center'; ctx.fillText('W', W_X, HDR_Y)
  ctx.textAlign = 'center'; ctx.fillText('L', L_X, HDR_Y)
  ctx.textAlign = 'right';  ctx.fillText('+/-', DIFF_X, HDR_Y)
  ctx.restore()

  // Rows
  const ROWS_Y = CARD_Y + CARD_PAD_TOP + TITLE_H + HDR_H

  standings.forEach((row, i) => {
    const rowY = ROWS_Y + i * (ROW_H + ROW_GAP)
    const baseline = rowY + ROW_H * 0.65
    const isAdvancing = i < 2

    if (isAdvancing) {
      ctx.save()
      ctx.fillStyle = 'rgba(250,204,21,0.07)'
      ctx.beginPath()
      ctx.roundRect(CARD_X + 16, rowY, CARD_W - 32, ROW_H, 16)
      ctx.fill()
      ctx.restore()
    }

    // Rank
    ctx.save()
    ctx.font = `bold 44px Arial, sans-serif`
    ctx.fillStyle = isAdvancing ? '#facc15' : '#475569'
    ctx.textAlign = 'center'
    ctx.fillText(String(i + 1), INNER_X - 10, baseline)
    ctx.restore()

    // Name
    ctx.save()
    ctx.font = `bold 40px Arial, sans-serif`
    ctx.fillStyle = isAdvancing ? '#fef08a' : '#64748b'
    ctx.textAlign = 'left'
    const nameX = INNER_X + 50
    const maxW = W_X - nameX - 40
    let name = getPairName(row.pairId)
    while (ctx.measureText(name).width > maxW && name.length > 1) name = name.slice(0, -1)
    if (name !== getPairName(row.pairId)) name += '…'
    ctx.fillText(name, nameX, baseline)
    ctx.restore()

    // W
    ctx.save()
    ctx.font = 'bold 36px monospace'
    ctx.fillStyle = isAdvancing ? '#e2e8f0' : '#64748b'
    ctx.textAlign = 'center'
    ctx.fillText(String(row.wins), W_X, baseline)
    ctx.restore()

    // L
    ctx.save()
    ctx.font = 'bold 36px monospace'
    ctx.fillStyle = isAdvancing ? '#e2e8f0' : '#64748b'
    ctx.textAlign = 'center'
    ctx.fillText(String(row.losses), L_X, baseline)
    ctx.restore()

    // +/-
    ctx.save()
    ctx.font = 'bold 36px monospace'
    ctx.fillStyle = row.pointDiff > 0 ? '#4ade80' : row.pointDiff < 0 ? '#f87171' : '#475569'
    ctx.textAlign = 'right'
    ctx.fillText(row.pointDiff > 0 ? `+${row.pointDiff}` : row.pointDiff === 0 ? '—' : String(row.pointDiff), DIFF_X, baseline)
    ctx.restore()

    // Yellow dot
    if (isAdvancing) {
      ctx.save()
      ctx.fillStyle = '#facc15'
      ctx.beginPath()
      ctx.arc(DOT_X, rowY + ROW_H / 2, 8, 0, Math.PI * 2)
      ctx.fill()
      ctx.restore()
    }
  })
}
```

- [ ] **Step 4: Implement `handleDownloadGroup` replacing the placeholder**

Remove the placeholder `handleDownloadGroup` from Task 3 and replace with the real implementation. This goes inside the component function, after the `overlays` state:

```typescript
const handleDownloadGroup = async (
  g: GroupId,
  groupMatches: TournamentMatch[],
  pairIds: string[],
  allMatches: TournamentMatch[],
) => {
  const canvas = document.createElement('canvas')
  const triggerDownload = (blob: Blob, filename: string) => {
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = filename
    a.click()
    URL.revokeObjectURL(url)
  }

  // Generate match posts for matches with photos
  let matchIndex = 1
  for (const m of groupMatches) {
    const photo = matchPhotos[m.id]
    if (!photo || m.scoreA === null || m.scoreB === null) { matchIndex++; continue }
    drawMatchPost(
      canvas,
      photo,
      getPairName(m.pairAId),
      getPairName(m.pairBId),
      m.scoreA,
      m.scoreB,
      g,
      matchIndex,
      overlays.logo,
    )
    await new Promise<void>(resolve => {
      canvas.toBlob(blob => {
        if (blob) triggerDownload(blob, `group-${g.toLowerCase()}-match-${matchIndex}.jpg`)
        resolve()
      }, 'image/jpeg', 0.92)
    })
    matchIndex++
  }

  // Generate group summary
  const standings = computeGroupStandings(g, pairIds, allMatches)
  drawGroupSummary(canvas, g, standings, getPairName, overlays.storyBg)
  await new Promise<void>(resolve => {
    canvas.toBlob(blob => {
      if (blob) triggerDownload(blob, `group-${g.toLowerCase()}-summary.jpg`)
      resolve()
    }, 'image/jpeg', 0.92)
  })
}
```

- [ ] **Step 5: Verify build**

```bash
npm run build
```

Expected: no TypeScript errors.

- [ ] **Step 6: End-to-end test in browser**

```bash
npm run dev
```

1. Go to Tournament → lock groups → Groups tab shows GroupMatches.
2. Enter scores for at least 2–3 matches in Group A.
3. Tap the camera icon in Group A header → turns yellow, camera buttons appear per row.
4. Upload a photo on a match that has a score.
5. Tap the yellow download button → check Downloads folder:
   - `group-a-match-N.jpg` — photo with header band and score footer at bottom.
   - `group-a-summary.jpg` — amber/yellow background with dark card, standings table (top 2 highlighted with yellow dot).
6. Verify pair names and score are readable on the match post.
7. Tap camera icon again → post mode off, upload UI hidden.

- [ ] **Step 7: Commit**

```bash
git add src/components/tournament/GroupMatches.tsx
git commit -m "feat: generate match photo posts and group summary standings card per group"
```

---

## Self-Review Notes

- **Spec coverage:** toggle button ✓, per-match upload ✓, green dot badge ✓, photo counter ✓, yellow download button ✓, match post canvas (photo + header + score footer) ✓, group summary (storyBg + standings table, top 2 dot) ✓, filenames ✓, skips matches without photos ✓.
- **No placeholders:** all steps have full code.
- **Type consistency:** `handleDownloadGroup` signature matches call site in download bar. `drawMatchPost` and `drawGroupSummary` signatures consistent across definition and call. `StandingRow` imported inline in `drawGroupSummary` — matches `computeGroupStandings` return type.
- **`computeGroupStandings`** already imported at top of `GroupMatches.tsx` — no new import needed for that.
