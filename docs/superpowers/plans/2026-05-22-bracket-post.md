# Bracket Post Feature Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-match photo upload and branded post generation to the bracket tab (QF/SF/Final), mirroring the existing group match post feature.

**Architecture:** Extract the shared `drawMatchPost` canvas function from GroupMatches into canvasPost.ts, then add post-mode state + UI to BracketTab. BracketTab's `MatchCard` sub-component is refactored from a `<button>` wrapper to a `<div>` so a sibling camera button can sit next to the score button without invalid HTML nesting.

**Tech Stack:** React 19, TypeScript, HTML5 Canvas 2D API, Tailwind v4

---

## File Map

| File | Action |
|------|--------|
| `src/utils/canvasPost.ts` | Add: export `drawMatchPost` function (moved from GroupMatches) |
| `src/components/tournament/GroupMatches.tsx` | Modify: import `drawMatchPost` from canvasPost instead of defining locally |
| `src/components/tournament/BracketTab.tsx` | Modify: refactor MatchCard, add post mode state/UI/handlers |

---

### Task 1: Extract `drawMatchPost` to `canvasPost.ts`

**Files:**
- Modify: `src/utils/canvasPost.ts`
- Modify: `src/components/tournament/GroupMatches.tsx`

- [ ] **Step 1: Copy `drawMatchPost` into `canvasPost.ts`**

Add this export to the bottom of `src/utils/canvasPost.ts` (after the existing `drawHeader` function). The subtitle parameter replaces the hardcoded `GROUP ${groupId} · MATCH ${matchIndex}` string:

```ts
export function drawMatchPost(
  canvas: HTMLCanvasElement,
  photo: HTMLImageElement,
  pairAName: string,
  pairBName: string,
  scoreA: number,
  scoreB: number,
  subtitle: string,
  logo: HTMLImageElement | undefined,
  badge: HTMLImageElement | undefined,
  chevrons: HTMLImageElement | undefined,
  sponsor: HTMLImageElement | undefined,
) {
  const W = 1080
  const H = 1350
  canvas.width = W
  canvas.height = H
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, W, H)

  // Layer 1: full-bleed photo
  const pScale = Math.max(W / photo.naturalWidth, H / photo.naturalHeight)
  ctx.drawImage(photo, (W - photo.naturalWidth * pScale) / 2, (H - photo.naturalHeight * pScale) / 2, photo.naturalWidth * pScale, photo.naturalHeight * pScale)

  // Chevrons
  if (chevrons) {
    const hLeft = 115
    const wLeft = hLeft * (chevrons.naturalWidth / chevrons.naturalHeight)
    const hRight = 115
    const wRight = hRight * (chevrons.naturalWidth / chevrons.naturalHeight)
    ctx.drawImage(chevrons, W - wRight - 30, H * 0.18, wRight, hRight)
    ctx.save()
    ctx.translate(30 + wLeft / 2, H * 0.10 + hLeft / 2)
    ctx.rotate(Math.PI)
    ctx.drawImage(chevrons, -wLeft / 2, -hLeft / 2, wLeft, hLeft)
    ctx.restore()
  }

  // Header band
  drawHeader(ctx, W, logo)

  // Footer
  const footerH = 230
  const footerY = H - footerH
  ctx.save()
  ctx.fillStyle = 'rgba(0,0,0,0.85)'
  ctx.fillRect(0, footerY, W, footerH)
  ctx.restore()

  // Sponsor logo inside footer
  if (sponsor) {
    const sH = 60
    const sW = sH * (sponsor.naturalWidth / sponsor.naturalHeight)
    ctx.drawImage(sponsor, (W - sW) / 2, footerY + 15, sW, sH)
  }

  // Names + score row
  const rowY = footerY + 140
  const maxNameW = 360
  ctx.save()
  ctx.font = 'bold 36px Arial, sans-serif'
  ctx.fillStyle = '#ffffff'
  ctx.textAlign = 'left'
  let nameA = pairAName
  while (ctx.measureText(nameA).width > maxNameW && nameA.length > 1) nameA = nameA.slice(0, -1)
  if (nameA !== pairAName) nameA += '…'
  ctx.fillText(nameA, 60, rowY)
  ctx.restore()

  ctx.save()
  ctx.font = 'bold 36px Arial, sans-serif'
  ctx.fillStyle = '#ffffff'
  ctx.textAlign = 'right'
  let nameB = pairBName
  while (ctx.measureText(nameB).width > maxNameW && nameB.length > 1) nameB = nameB.slice(0, -1)
  if (nameB !== pairBName) nameB += '…'
  ctx.fillText(nameB, W - 60, rowY)
  ctx.restore()

  ctx.save()
  ctx.font = 'bold 42px monospace'
  ctx.fillStyle = '#facc15'
  ctx.textAlign = 'center'
  ctx.fillText(`${scoreA} – ${scoreB}`, W / 2, rowY)
  ctx.restore()

  // Badge low opacity
  if (badge) {
    const badgeH = 200
    const badgeW = badgeH * (badge.naturalWidth / badge.naturalHeight)
    ctx.save()
    ctx.globalAlpha = 0.18
    ctx.drawImage(badge, W - badgeW + 20, footerY + (footerH - badgeH) / 2, badgeW, badgeH)
    ctx.restore()
  }

  // Subtitle
  ctx.save()
  ctx.font = '20px monospace'
  ctx.fillStyle = '#64748b'
  ctx.textAlign = 'center'
  ctx.fillText(subtitle, W / 2, footerY + 205)
  ctx.restore()
}
```

- [ ] **Step 2: Update `GroupMatches.tsx` to import and use the shared function**

At the top of `GroupMatches.tsx`, update the import:
```ts
import { loadImage, drawHeader, drawMatchPost } from '../../utils/canvasPost'
```

Then delete the local `drawMatchPost` function definition (lines 22–126 in the current file — the entire function from `function drawMatchPost(` through its closing `}`).

Update the call site in `handleDownloadGroup` to use the new signature (subtitle string instead of groupId + matchIndex):
```ts
drawMatchPost(
  matchCanvas,
  photo,
  getPairName(m.pairAId),
  getPairName(m.pairBId),
  m.scoreA,
  m.scoreB,
  `GROUP ${g} · MATCH ${matchIndex}`,
  overlays.logo,
  overlays.badge,
  overlays.chevrons,
  overlays.sponsor,
)
```

- [ ] **Step 3: Verify the app still compiles**

```bash
npm run build
```
Expected: no TypeScript errors, build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/utils/canvasPost.ts src/components/tournament/GroupMatches.tsx
git commit -m "refactor: extract drawMatchPost to canvasPost.ts for sharing"
```

---

### Task 2: Add post mode to `BracketTab.tsx`

**Files:**
- Modify: `src/components/tournament/BracketTab.tsx`

- [ ] **Step 1: Update imports and add new state/refs**

Replace the current import line at the top of `BracketTab.tsx`:
```ts
import { useState } from 'react'
```
with:
```ts
import { useState, useRef, useEffect } from 'react'
import { loadImage, drawHeader, drawMatchPost } from '../../utils/canvasPost'
```

Inside the `BracketTab` component function, after the existing `const [activeMatchId, ...]` state, add:
```ts
const [postModeRounds, setPostModeRounds] = useState<Record<string, boolean>>({})
const [bracketPhotos, setBracketPhotos] = useState<Record<string, HTMLImageElement>>({})
const [overlays, setOverlays] = useState<{
  logo?: HTMLImageElement
  badge?: HTMLImageElement
  chevrons?: HTMLImageElement
  sponsor?: HTMLImageElement
}>({})
const activeUploadMatchId = useRef<string | null>(null)
const fileInputRef = useRef<HTMLInputElement>(null)
```

- [ ] **Step 2: Load overlay images on mount**

Add this `useEffect` inside `BracketTab`, after the state declarations:
```ts
useEffect(() => {
  const load = async () => {
    const result: typeof overlays = {}
    try { result.logo = await loadImage('/instagram-logo.png') } catch { /* skip */ }
    try { result.badge = await loadImage('/tournament-badge.png') } catch { /* skip */ }
    try { result.chevrons = await loadImage('/chevrons.png') } catch { /* skip */ }
    try { result.sponsor = await loadImage('/sponsor-logo.png') } catch { /* skip */ }
    setOverlays(result)
  }
  load()
}, [])
```

- [ ] **Step 3: Add the subtitle helper and download handler**

Add these two helpers inside `BracketTab`, before the `return` statement:

```ts
const bracketSubtitle = (matchId: string): string => {
  const map: Record<string, string> = {
    'qf-1': 'QUARTERFINAL · QF 1',
    'qf-2': 'QUARTERFINAL · QF 2',
    'qf-3': 'QUARTERFINAL · QF 3',
    'qf-4': 'QUARTERFINAL · QF 4',
    'sf-1': 'SEMIFINAL · SF 1',
    'sf-2': 'SEMIFINAL · SF 2',
    'final-1': 'FINAL',
    '3rd-1': '3RD PLACE',
  }
  return map[matchId] ?? matchId.toUpperCase()
}

const handleDownloadRound = async (roundMatchIds: string[]) => {
  const suffix = Math.floor(Math.random() * 90000) + 10000
  const blobOf = (c: HTMLCanvasElement) => new Promise<Blob | null>(res => c.toBlob(res, 'image/jpeg', 0.92))
  const files: File[] = []

  for (const id of roundMatchIds) {
    const photo = bracketPhotos[id]
    const match = matches.find(m => m.id === id)
    if (!photo || !match || match.scoreA === null || match.scoreB === null) continue
    const c = document.createElement('canvas')
    drawMatchPost(
      c,
      photo,
      getPairName(match.pairAId),
      getPairName(match.pairBId),
      match.scoreA,
      match.scoreB,
      bracketSubtitle(id),
      overlays.logo,
      overlays.badge,
      overlays.chevrons,
      overlays.sponsor,
    )
    const blob = await blobOf(c)
    if (blob) files.push(new File([blob], `bracket-${id}-${suffix}.jpg`, { type: 'image/jpeg' }))
  }

  if (files.length === 0) return

  const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent)
  if (isIOS && navigator.canShare?.({ files })) {
    await navigator.share({ files, title: 'Bracket Photos' })
  } else {
    for (const file of files) {
      const url = URL.createObjectURL(file)
      const a = document.createElement('a')
      a.href = url
      a.download = file.name
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      await new Promise<void>(r => setTimeout(() => { URL.revokeObjectURL(url); r() }, 300))
    }
  }
}
```

- [ ] **Step 4: Add the file input handler**

Add this helper inside `BracketTab`, before the `return`:
```ts
const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
  const file = e.target.files?.[0]
  const matchId = activeUploadMatchId.current
  if (!file || !matchId) return
  const img = new Image()
  img.onload = () => setBracketPhotos(prev => ({ ...prev, [matchId]: img }))
  img.src = URL.createObjectURL(file)
  e.target.value = ''
}
```

- [ ] **Step 5: Refactor `MatchCard` to support a sibling camera button**

Replace the entire `MatchCard` component (lines 14–50 in current file) with this version. It changes from a `<button>` root to a `<div>` root so a camera button can sit alongside the score button without invalid nesting:

```tsx
function MatchCard({
  match,
  label,
  borderColor,
  labelColor,
  getPairName,
  onSelect,
  showPostIcon,
  hasPhoto,
  onUploadPhoto,
}: {
  match?: TournamentMatch
  label: string
  borderColor: string
  labelColor: string
  getPairName: (id: string | null) => string
  onSelect: (match: TournamentMatch) => void
  showPostIcon?: boolean
  hasPhoto?: boolean
  onUploadPhoto?: () => void
}) {
  if (!match) return <div className="h-16 bg-slate-800/30 rounded-lg" />
  const canEnter = !!(match.pairAId && match.pairBId)
  const scored = match.scoreA !== null
  return (
    <div className={`w-full bg-slate-800 rounded-lg border-l-2 ${borderColor} overflow-hidden flex items-stretch`}>
      <button
        onClick={() => canEnter && onSelect(match)}
        disabled={!canEnter}
        className="flex-1 text-left disabled:opacity-60 hover:bg-slate-700/50 disabled:hover:bg-transparent"
      >
        <div className={`px-2 py-1.5 border-b border-slate-700 text-[8px] font-bold tracking-wide ${labelColor}`}>{label}</div>
        <div className="px-2 pt-2 pb-1">
          <div className="text-xs text-slate-200 font-medium truncate">{getPairName(match.pairAId)}</div>
          {scored ? (
            <div className="text-[10px] font-bold text-yellow-400 text-center my-1">{match.scoreA} – {match.scoreB}</div>
          ) : (
            <div className="text-[9px] text-slate-600 text-center my-1">vs</div>
          )}
          <div className="text-xs text-slate-200 font-medium truncate">{getPairName(match.pairBId)}</div>
        </div>
      </button>
      {showPostIcon && (
        <div className="relative flex items-center pr-2 shrink-0">
          <button
            aria-label={`Upload photo for ${getPairName(match.pairAId)} vs ${getPairName(match.pairBId)}`}
            onClick={onUploadPhoto}
            className="w-7 h-7 rounded-full bg-black/50 flex items-center justify-center active:bg-black/70"
          >
            <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="white" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
              <circle cx="12" cy="13" r="4"/>
            </svg>
          </button>
          {hasPhoto && (
            <span className="absolute top-2 right-1.5 w-2 h-2 rounded-full bg-green-500 border border-slate-800" />
          )}
        </div>
      )}
    </div>
  )
}
```

- [ ] **Step 6: Update round column headers with camera + download icons**

The current column headers row is:
```tsx
<div className="grid grid-cols-[1fr_10px_1fr_10px_1fr] mb-2 text-[10px] text-slate-400 uppercase tracking-widest font-semibold">
  <span className="text-center">QF</span>
  <span />
  <span className="text-center">SF</span>
  <span />
  <span className="text-center">Final</span>
</div>
```

Replace it with:
```tsx
<div className="grid grid-cols-[1fr_10px_1fr_10px_1fr] mb-2 text-[10px] text-slate-400 uppercase tracking-widest font-semibold">
  {/* QF header */}
  <div className="flex items-center justify-center gap-1.5">
    <span>QF</span>
    <button
      onClick={() => setPostModeRounds(prev => ({ ...prev, qf: !prev.qf }))}
      className={`w-7 h-7 rounded-full flex items-center justify-center transition-colors ${postModeRounds.qf ? 'bg-yellow-400 active:bg-yellow-300' : 'bg-black/50 active:bg-black/70'}`}
    >
      <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke={postModeRounds.qf ? 'black' : 'white'} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
        <circle cx="12" cy="13" r="4"/>
      </svg>
    </button>
    {postModeRounds.qf && ['qf-1','qf-2','qf-3','qf-4'].some(id => bracketPhotos[id]) && (
      <button
        aria-label="Download QF posts"
        onClick={() => handleDownloadRound(['qf-1','qf-2','qf-3','qf-4'])}
        className="w-7 h-7 rounded-full bg-yellow-400 flex items-center justify-center active:bg-yellow-300"
      >
        <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="black" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
          <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
          <polyline points="7 10 12 15 17 10"/>
          <line x1="12" y1="15" x2="12" y2="3"/>
        </svg>
      </button>
    )}
  </div>
  <span />
  {/* SF header */}
  <div className="flex items-center justify-center gap-1.5">
    <span>SF</span>
    <button
      onClick={() => setPostModeRounds(prev => ({ ...prev, sf: !prev.sf }))}
      className={`w-7 h-7 rounded-full flex items-center justify-center transition-colors ${postModeRounds.sf ? 'bg-yellow-400 active:bg-yellow-300' : 'bg-black/50 active:bg-black/70'}`}
    >
      <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke={postModeRounds.sf ? 'black' : 'white'} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
        <circle cx="12" cy="13" r="4"/>
      </svg>
    </button>
    {postModeRounds.sf && ['sf-1','sf-2'].some(id => bracketPhotos[id]) && (
      <button
        aria-label="Download SF posts"
        onClick={() => handleDownloadRound(['sf-1','sf-2'])}
        className="w-7 h-7 rounded-full bg-yellow-400 flex items-center justify-center active:bg-yellow-300"
      >
        <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="black" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
          <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
          <polyline points="7 10 12 15 17 10"/>
          <line x1="12" y1="15" x2="12" y2="3"/>
        </svg>
      </button>
    )}
  </div>
  <span />
  {/* Final header */}
  <div className="flex items-center justify-center gap-1.5">
    <span>Final</span>
    <button
      onClick={() => setPostModeRounds(prev => ({ ...prev, final: !prev.final }))}
      className={`w-7 h-7 rounded-full flex items-center justify-center transition-colors ${postModeRounds.final ? 'bg-yellow-400 active:bg-yellow-300' : 'bg-black/50 active:bg-black/70'}`}
    >
      <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke={postModeRounds.final ? 'black' : 'white'} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
        <circle cx="12" cy="13" r="4"/>
      </svg>
    </button>
    {postModeRounds.final && ['final-1','3rd-1'].some(id => bracketPhotos[id]) && (
      <button
        aria-label="Download Final posts"
        onClick={() => handleDownloadRound(['final-1','3rd-1'])}
        className="w-7 h-7 rounded-full bg-yellow-400 flex items-center justify-center active:bg-yellow-300"
      >
        <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="black" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
          <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
          <polyline points="7 10 12 15 17 10"/>
          <line x1="12" y1="15" x2="12" y2="3"/>
        </svg>
      </button>
    )}
  </div>
</div>
```

- [ ] **Step 7: Pass post mode props to all MatchCard usages**

Update all six `<MatchCard ... />` calls in the JSX to pass `showPostIcon`, `hasPhoto`, and `onUploadPhoto` props. Also add the hidden file input just before the closing `</div>` of the component return.

Replace the upper-half bracket grid:
```tsx
{/* Upper half: QF1+QF2 → SF1 → Final */}
<div className="grid grid-cols-[1fr_10px_1fr_10px_1fr] items-center mb-3">
  <div className="flex flex-col gap-3">
    <MatchCard match={qf1} label="QF 1 · A1 vs B2" borderColor="border-sky-500" labelColor="text-sky-400" getPairName={getPairName} onSelect={handleSelect}
      showPostIcon={postModeRounds.qf} hasPhoto={!!bracketPhotos['qf-1']} onUploadPhoto={() => { activeUploadMatchId.current = 'qf-1'; fileInputRef.current?.click() }} />
    <MatchCard match={qf2} label="QF 2 · C2 vs D1" borderColor="border-sky-500" labelColor="text-sky-400" getPairName={getPairName} onSelect={handleSelect}
      showPostIcon={postModeRounds.qf} hasPhoto={!!bracketPhotos['qf-2']} onUploadPhoto={() => { activeUploadMatchId.current = 'qf-2'; fileInputRef.current?.click() }} />
  </div>
  <Connector />
  <MatchCard match={sf1} label="SEMI 1" borderColor="border-violet-500" labelColor="text-violet-400" getPairName={getPairName} onSelect={handleSelect}
    showPostIcon={postModeRounds.sf} hasPhoto={!!bracketPhotos['sf-1']} onUploadPhoto={() => { activeUploadMatchId.current = 'sf-1'; fileInputRef.current?.click() }} />
  <Connector />
  <MatchCard match={final} label="🏆 FINAL" borderColor="border-yellow-500" labelColor="text-yellow-400" getPairName={getPairName} onSelect={handleSelect}
    showPostIcon={postModeRounds.final} hasPhoto={!!bracketPhotos['final-1']} onUploadPhoto={() => { activeUploadMatchId.current = 'final-1'; fileInputRef.current?.click() }} />
</div>
```

Replace the lower-half bracket grid:
```tsx
{/* Lower half: QF3+QF4 → SF2 | 3RD PLACE (no connector) */}
<div className="grid grid-cols-[1fr_10px_1fr_10px_1fr] items-center">
  <div className="flex flex-col gap-3">
    <MatchCard match={qf3} label="QF 3 · C1 vs D2" borderColor="border-sky-500" labelColor="text-sky-400" getPairName={getPairName} onSelect={handleSelect}
      showPostIcon={postModeRounds.qf} hasPhoto={!!bracketPhotos['qf-3']} onUploadPhoto={() => { activeUploadMatchId.current = 'qf-3'; fileInputRef.current?.click() }} />
    <MatchCard match={qf4} label="QF 4 · A2 vs B1" borderColor="border-sky-500" labelColor="text-sky-400" getPairName={getPairName} onSelect={handleSelect}
      showPostIcon={postModeRounds.qf} hasPhoto={!!bracketPhotos['qf-4']} onUploadPhoto={() => { activeUploadMatchId.current = 'qf-4'; fileInputRef.current?.click() }} />
  </div>
  <Connector />
  <MatchCard match={sf2} label="SEMI 2" borderColor="border-violet-500" labelColor="text-violet-400" getPairName={getPairName} onSelect={handleSelect}
    showPostIcon={postModeRounds.sf} hasPhoto={!!bracketPhotos['sf-2']} onUploadPhoto={() => { activeUploadMatchId.current = 'sf-2'; fileInputRef.current?.click() }} />
  <span />
  <MatchCard match={third} label="🥉 3RD" borderColor="border-slate-600" labelColor="text-slate-500" getPairName={getPairName} onSelect={handleSelect}
    showPostIcon={postModeRounds.final} hasPhoto={!!bracketPhotos['3rd-1']} onUploadPhoto={() => { activeUploadMatchId.current = '3rd-1'; fileInputRef.current?.click() }} />
</div>
```

Add the hidden file input just before the closing `</div>` of the whole component return (after the `ScoreModal`):
```tsx
<input
  ref={fileInputRef}
  type="file"
  accept="image/*"
  className="hidden"
  onChange={handleFileChange}
/>
```

- [ ] **Step 8: Verify build**

```bash
npm run build
```
Expected: no TypeScript errors, build succeeds.

- [ ] **Step 9: Commit**

```bash
git add src/components/tournament/BracketTab.tsx
git commit -m "feat: add per-match post mode to bracket tab (QF/SF/Final)"
```

---

### Task 3: Smoke test in browser

- [ ] **Step 1: Start dev server**

```bash
npm run dev
```

- [ ] **Step 2: Verify group post still works**

Navigate to Tournament → Groups tab. Confirm the camera icon still appears on group headers and generates downloadable posts as before (regression check).

- [ ] **Step 3: Verify bracket post mode**

Navigate to Tournament → Bracket tab (requires groups to be confirmed so matches are populated).

1. Tap the camera icon on the **QF** column header → it should turn yellow
2. Each QF match card should show a small camera icon on its right side
3. Tap a camera icon on a match → file picker opens → select any image
4. The camera icon should show a green dot after selecting
5. The download icon (yellow round button) should appear in the QF header
6. Tap the download icon → confirm image downloads / share sheet appears (iOS)
7. Verify the downloaded JPG has the correct footer label (e.g. "QUARTERFINAL · QF 1")
8. Repeat for SF and Final columns
9. Tap the active camera icon again → post mode turns off, camera icons on match cards disappear
