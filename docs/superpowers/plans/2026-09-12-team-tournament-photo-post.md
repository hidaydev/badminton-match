# Team Tournament Photo Post Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-partai and team-match-summary Instagram post export to the Team Tournament's Schedule and Final tabs, mirroring the classic tournament's `GroupMatches.tsx` pattern.

**Architecture:** Extract `MatchCard` to its own component file, add `drawTeamMatchPost` to the existing canvas utility, create `TeamGroupSchedule` component with camera-toggle post mode, and wire champion photo export into the Final tab.

**Tech Stack:** React 19, TypeScript, HTML5 Canvas, `apps/web/src/utils/canvasPost.ts`, `apps/web/src/utils/share.ts`, `apps/web/src/utils/overlays.ts`

---

## File Map

| Action | File | Purpose |
|--------|------|---------|
| Create | `apps/web/src/components/tournament/TeamMatchCard.tsx` | Extracted `MatchCard` + `teamName` helper — shared by group schedule and final tab |
| Modify | `apps/web/src/utils/canvasPost.ts` | Add `drawTeamMatchPost()` for team-vs-team summary post |
| Create | `apps/web/src/components/tournament/TeamGroupSchedule.tsx` | Schedule tab group matches + camera toggle + photo upload + download |
| Modify | `apps/web/src/pages/TeamTournamentPage.tsx` | Use `TeamMatchCard`, use `TeamGroupSchedule`, add Final tab champion export |

---

## Task 1: Extract MatchCard to TeamMatchCard.tsx

**Files:**
- Create: `apps/web/src/components/tournament/TeamMatchCard.tsx`
- Modify: `apps/web/src/pages/TeamTournamentPage.tsx`

- [ ] **Step 1: Create `TeamMatchCard.tsx`**

```tsx
// apps/web/src/components/tournament/TeamMatchCard.tsx
import { teamMatchOutcome, teamTarget, PARTAI_CLASSES, type TeamMatch, type TeamInfo } from '../../utils/teamTournament'

export function teamName(teams: { id: string; name: string }[], id: string | undefined): string {
  return teams.find((t) => t.id === id)?.name ?? (id ?? '—')
}

export default function TeamMatchCard({
  match,
  teams,
  saving,
  matchIdx,
  onChange,
  onUpdateCourt,
  onSave,
}: {
  match: TeamMatch
  teams: TeamInfo[]
  saving: boolean
  matchIdx: number
  onChange: (matchIdx: number, partaiIdx: number, patch: Partial<{ scoreA: number | null; scoreB: number | null }>) => void
  onUpdateCourt: (matchIdx: number, courtIdx: number, name: string) => void
  onSave: () => void
}) {
  const out = teamMatchOutcome(match)
  const target = teamTarget(match.phase)
  const defaultCourts = ['Court 12', 'Court 13', 'Court 14']
  const courts = match.courts ?? defaultCourts
  const courtsChanged = courts.some((c, i) => c !== defaultCourts[i])
  const dirty = match.partai.some((p) => p.scoreA !== null || p.scoreB !== null) || courtsChanged
  const label = match.phase === 'final'
    ? `FINAL · ${teamName(teams, match.teamA)} vs ${teamName(teams, match.teamB)}`
    : `Group · ${teamName(teams, match.teamA)} vs ${teamName(teams, match.teamB)}`

  const getTeamPlayer = (teamId: string, cls: string) => {
    const team = teams.find((t) => t.id === teamId)
    return team?.players.find((p) => p.cls === cls)?.name ?? '—'
  }

  return (
    <div className="bg-surface border border-border-subtle rounded-lg overflow-hidden">
      <div className="flex items-center justify-between px-4 py-2 border-b border-border-subtle">
        <span className="text-xs text-fg-dim uppercase tracking-wider">{label}</span>
        {dirty && (
          <span className="text-[11px] text-fg-dim">
            {out.complete ? `${out.aWins}-${out.bWins}` : 'incomplete'}
          </span>
        )}
      </div>
      <div className="px-4 py-3 flex flex-col gap-3">
        {PARTAI_CLASSES.map(([clsA, clsB], pi) => (
          <div key={pi} className="flex flex-col gap-1">
            <div className="flex items-center gap-2">
              <span className="w-12 text-[11px] text-fg-dim uppercase shrink-0">{clsA} {clsB}</span>
              <span className="flex-1 text-[11px] text-fg-dim truncate">
                {getTeamPlayer(match.teamA, clsA)}/{getTeamPlayer(match.teamA, clsB)}
              </span>
              <input
                type="number"
                min={0}
                max={target}
                value={match.partai[pi].scoreA ?? ''}
                onChange={(e) => onChange(matchIdx, pi, { scoreA: e.target.value === '' ? null : Math.max(0, Number(e.target.value)) })}
                className="w-14 bg-elevated border border-border rounded-md px-2 py-1.5 text-sm font-sans text-fg text-center focus:border-accent focus:outline-none"
                aria-label={`Score ${teamName(teams, match.teamA)} partai ${pi + 1}`}
              />
              <span className="text-fg-dim text-xs shrink-0">:</span>
              <input
                type="number"
                min={0}
                max={target}
                value={match.partai[pi].scoreB ?? ''}
                onChange={(e) => onChange(matchIdx, pi, { scoreB: e.target.value === '' ? null : Math.max(0, Number(e.target.value)) })}
                className="w-14 bg-elevated border border-border rounded-md px-2 py-1.5 text-sm font-sans text-fg text-center focus:border-accent focus:outline-none"
                aria-label={`Score ${teamName(teams, match.teamB)} partai ${pi + 1}`}
              />
              <span className="flex-1 text-[11px] text-fg-dim truncate text-right">
                {getTeamPlayer(match.teamB, clsA)}/{getTeamPlayer(match.teamB, clsB)}
              </span>
            </div>
            <div className="flex items-center gap-2 pl-14">
              <span className="text-[11px] text-fg-dim">Court</span>
              <input
                type="text"
                value={courts[pi]}
                onChange={(e) => onUpdateCourt(matchIdx, pi, e.target.value)}
                className="flex-1 bg-transparent text-xs text-fg-dim border-b border-border-subtle focus:border-accent focus:outline-none"
                placeholder={`Court ${pi + 1}`}
              />
            </div>
          </div>
        ))}
      </div>
      <div className="px-4 pb-3">
        <button
          onClick={onSave}
          disabled={saving || !dirty}
          className="w-full py-2 rounded-lg bg-accent/15 border border-accent/30 text-accent text-sm font-bold disabled:opacity-40"
        >
          {saving ? 'Saving…' : 'Save'}
        </button>
      </div>
    </div>
  )
}
```

- [ ] **Step 2: Update `TeamTournamentPage.tsx` — swap local definitions for imports**

At the top of `TeamTournamentPage.tsx`, add:
```tsx
import TeamMatchCard, { teamName } from '../components/tournament/TeamMatchCard'
```

Remove the local `function teamName(...)` definition (line ~356) and the local `function MatchCard(...)` definition (lines ~360–461) from `TeamTournamentPage.tsx`.

In the Final tab JSX, replace `<MatchCard` with `<TeamMatchCard` (same props — no prop changes needed).

In the `jadwal` tab JSX, also replace `<MatchCard` with `<TeamMatchCard`.

- [ ] **Step 3: Build to confirm no TypeScript errors**

```bash
cd apps/web && npm run build 2>&1 | tail -20
```

Expected: build succeeds with no type errors.

- [ ] **Step 4: Commit**

```bash
git add apps/web/src/components/tournament/TeamMatchCard.tsx apps/web/src/pages/TeamTournamentPage.tsx
git commit -m "refactor: extract MatchCard to TeamMatchCard component"
```

---

## Task 2: Add `drawTeamMatchPost` to `canvasPost.ts`

**Files:**
- Modify: `apps/web/src/utils/canvasPost.ts`

- [ ] **Step 1: Add the function at the end of `canvasPost.ts`**

Append after the `drawGroupSummary` export (line ~892):

```ts
// ── Team match summary post ──────────────────────────────────────────────────

export interface TeamMatchPartaiRow {
  tier: string
  nameA: string
  nameB: string
  scoreA: number | null
  scoreB: number | null
}

export function drawTeamMatchPost(
  canvas: HTMLCanvasElement,
  photo: HTMLImageElement,
  teamAName: string,
  teamBName: string,
  teamAWins: number,
  teamBWins: number,
  partaiRows: TeamMatchPartaiRow[],
  subtitle: string,
  logo: HTMLImageElement | undefined,
  chevrons: HTMLImageElement | undefined,
  sponsor: HTMLImageElement | undefined,
) {
  const W = POST_WIDTH
  const H = POST_HEIGHT
  canvas.width = W
  canvas.height = H
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, W, H)

  // Layer 1: full-bleed photo
  drawCoverFill(ctx, photo, W, H, 0, 0)

  // Chevrons — same positions as drawMatchPost
  if (chevrons) {
    const chevH = 115
    const chevW = chevH * (chevrons.naturalWidth / chevrons.naturalHeight)
    ctx.drawImage(chevrons, W - chevW - 30, H * 0.18, chevW, chevH)
    ctx.save()
    ctx.translate(30 + chevW / 2, H * 0.10 + chevH / 2)
    ctx.rotate(Math.PI)
    ctx.drawImage(chevrons, -chevW / 2, -chevH / 2, chevW, chevH)
    ctx.restore()
  }

  // Header band
  drawTournamentHeader(ctx, W, logo)

  // Dark footer — taller than drawMatchPost to fit partai rows
  const footerH = 340
  const footerY = H - footerH
  ctx.fillStyle = 'rgba(0,0,0,0.85)'
  ctx.fillRect(0, footerY, W, footerH)

  // Sponsor logo
  if (sponsor) {
    const sH = 50
    const sW = sH * (sponsor.naturalWidth / sponsor.naturalHeight)
    ctx.drawImage(sponsor, (W - sW) / 2, footerY + 14, sW, sH)
  }

  // Team names + overall score
  const scoreRowY = footerY + 130
  const maxTeamW = 340

  ctx.save()
  ctx.font = 'bold 36px Arial, sans-serif'
  ctx.fillStyle = C.white
  ctx.textAlign = 'left'
  ctx.fillText(truncateToWidth(ctx, teamAName, maxTeamW), 60, scoreRowY)
  ctx.restore()

  ctx.save()
  ctx.font = 'bold 36px Arial, sans-serif'
  ctx.fillStyle = C.muted
  ctx.textAlign = 'right'
  ctx.fillText(truncateToWidth(ctx, teamBName, maxTeamW), W - 60, scoreRowY)
  ctx.restore()

  ctx.save()
  ctx.font = 'bold 44px monospace'
  ctx.fillStyle = C.accent
  ctx.textAlign = 'center'
  ctx.fillText(`${teamAWins} – ${teamBWins}`, W / 2, scoreRowY)
  ctx.restore()

  // Divider
  ctx.save()
  ctx.strokeStyle = 'rgba(250,204,21,0.25)'
  ctx.lineWidth = 1
  ctx.beginPath()
  ctx.moveTo(60, scoreRowY + 22)
  ctx.lineTo(W - 60, scoreRowY + 22)
  ctx.stroke()
  ctx.restore()

  // Partai rows
  const partaiStartY = scoreRowY + 52
  const rowH = 48
  const maxPartaiNameW = 200

  partaiRows.forEach((row, i) => {
    const y = partaiStartY + i * rowH

    ctx.save()
    ctx.font = 'bold 20px monospace'
    ctx.fillStyle = C.accent
    ctx.textAlign = 'left'
    ctx.fillText(row.tier, 60, y)
    ctx.restore()

    ctx.save()
    ctx.font = 'bold 22px Arial, sans-serif'
    ctx.fillStyle = C.white
    ctx.textAlign = 'left'
    ctx.fillText(truncateToWidth(ctx, row.nameA, maxPartaiNameW), 160, y)
    ctx.restore()

    ctx.save()
    ctx.font = 'bold 22px monospace'
    ctx.fillStyle = C.accent
    ctx.textAlign = 'center'
    const score = row.scoreA !== null && row.scoreB !== null ? `${row.scoreA}–${row.scoreB}` : 'vs'
    ctx.fillText(score, W / 2, y)
    ctx.restore()

    ctx.save()
    ctx.font = 'bold 22px Arial, sans-serif'
    ctx.fillStyle = C.muted
    ctx.textAlign = 'right'
    ctx.fillText(truncateToWidth(ctx, row.nameB, maxPartaiNameW), W - 60, y)
    ctx.restore()
  })

  // Subtitle
  ctx.save()
  ctx.font = '18px monospace'
  ctx.fillStyle = C.muted
  ctx.textAlign = 'center'
  ctx.fillText(subtitle, W / 2, footerY + footerH - 18)
  ctx.restore()
}
```

- [ ] **Step 2: Build to confirm no TypeScript errors**

```bash
cd apps/web && npm run build 2>&1 | tail -20
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add apps/web/src/utils/canvasPost.ts
git commit -m "feat: add drawTeamMatchPost canvas function for team match summary post"
```

---

## Task 3: Create `TeamGroupSchedule.tsx`

**Files:**
- Create: `apps/web/src/components/tournament/TeamGroupSchedule.tsx`

- [ ] **Step 1: Create the component**

```tsx
// apps/web/src/components/tournament/TeamGroupSchedule.tsx
import { useEffect, useRef, useState } from 'react'
import {
  teamMatchOutcome,
  PARTAI_CLASSES,
  type TeamMatch,
  type TeamInfo,
} from '../../utils/teamTournament'
import TeamMatchCard, { teamName } from './TeamMatchCard'
import { drawMatchPost, drawTeamMatchPost, type TeamMatchPartaiRow } from '../../utils/canvasPost'
import type { OverlayImages } from '../../utils/canvasPost'
import { canvasToBlob, shareOrDownload } from '../../utils/share'
import { loadOverlayImages } from '../../utils/overlays'

interface TeamGroupScheduleProps {
  teams: TeamInfo[]
  matches: TeamMatch[]
  saving: boolean
  onChangePartai: (matchIdx: number, partaiIdx: number, patch: Partial<{ scoreA: number | null; scoreB: number | null }>) => void
  onUpdateCourt: (matchIdx: number, courtIdx: number, name: string) => void
  onSave: () => void
  onDraw: () => void
}

function getPairName(teams: TeamInfo[], teamId: string, clsA: string, clsB: string): string {
  const team = teams.find((t) => t.id === teamId)
  const p1 = team?.players.find((p) => p.cls === clsA)?.name ?? '—'
  const p2 = team?.players.find((p) => p.cls === clsB)?.name ?? '—'
  return `${p1}/${p2}`
}

export default function TeamGroupSchedule({
  teams,
  matches,
  saving,
  onChangePartai,
  onUpdateCourt,
  onSave,
  onDraw,
}: TeamGroupScheduleProps) {
  const groupMatches = matches.filter((m) => m.phase === 'group')

  // Post mode & photo state
  const [postModeMatches, setPostModeMatches] = useState<Record<string, boolean>>({})
  const [teamPhotos, setTeamPhotos] = useState<Record<string, HTMLImageElement>>({})
  const [partaiPhotos, setPartaiPhotos] = useState<Record<string, HTMLImageElement>>({})
  const [overlays, setOverlays] = useState<OverlayImages>({})
  const fileInputRef = useRef<HTMLInputElement>(null)
  const activeUploadKey = useRef<string | null>(null)

  useEffect(() => {
    loadOverlayImages({
      logo: '/instagram-logo.png',
      badge: '/tournament-badge.png',
      chevrons: '/chevrons.png',
      sponsor: '/sponsor-logo.png',
    }).then(setOverlays)
  }, [])

  const uploadedCount = (matchId: string): number => {
    let count = teamPhotos[matchId] ? 1 : 0
    for (let i = 0; i < PARTAI_CLASSES.length; i++) {
      if (partaiPhotos[`${matchId}-${i}`]) count++
    }
    return count
  }

  const handleDownload = async (m: TeamMatch) => {
    const matchIdx = matches.indexOf(m)
    if (matchIdx === -1) return
    const out = teamMatchOutcome(m)
    const tNameA = teamName(teams, m.teamA)
    const tNameB = teamName(teams, m.teamB)
    const slug = `${tNameA.toLowerCase().replace(/\s+/g, '-')}-vs-${tNameB.toLowerCase().replace(/\s+/g, '-')}`
    const files: File[] = []

    // Per-partai posts
    for (let pi = 0; pi < PARTAI_CLASSES.length; pi++) {
      const key = `${m.id}-${pi}`
      const photo = partaiPhotos[key]
      const p = m.partai[pi]
      if (!photo || p.scoreA === null || p.scoreB === null) continue
      const [clsA, clsB] = PARTAI_CLASSES[pi]
      const nameA = getPairName(teams, m.teamA, clsA, clsB)
      const nameB = getPairName(teams, m.teamB, clsA, clsB)
      const c = document.createElement('canvas')
      drawMatchPost(c, photo, nameA, nameB, p.scoreA, p.scoreB, `GROUP MATCH · ${clsA}${clsB}`, overlays.logo, overlays.badge, overlays.chevrons, overlays.sponsor)
      const blob = await canvasToBlob(c)
      if (blob) files.push(new File([blob], `${slug}-${clsA}${clsB}.jpg`, { type: 'image/jpeg' }))
    }

    // Team summary post
    const teamPhoto = teamPhotos[m.id]
    if (teamPhoto) {
      const partaiRows: TeamMatchPartaiRow[] = PARTAI_CLASSES.map(([clsA, clsB], pi) => ({
        tier: `${clsA}${clsB}`,
        nameA: getPairName(teams, m.teamA, clsA, clsB),
        nameB: getPairName(teams, m.teamB, clsA, clsB),
        scoreA: m.partai[pi].scoreA,
        scoreB: m.partai[pi].scoreB,
      }))
      const c = document.createElement('canvas')
      drawTeamMatchPost(c, teamPhoto, tNameA, tNameB, out.aWins, out.bWins, partaiRows, 'GROUP STAGE', overlays.logo, overlays.chevrons, overlays.sponsor)
      const blob = await canvasToBlob(c)
      if (blob) files.push(new File([blob], `${slug}-summary.jpg`, { type: 'image/jpeg' }))
    }

    if (files.length === 0) return
    await shareOrDownload(files, `${tNameA} vs ${tNameB}`)
  }

  return (
    <div className="flex flex-col gap-3">
      {groupMatches.length === 0 && (
        <button
          onClick={onDraw}
          disabled={saving}
          className="w-full py-3 rounded-lg bg-accent text-slate-950 font-bold text-sm disabled:opacity-40"
        >
          Group Draw (match day)
        </button>
      )}

      {groupMatches.map((m) => {
        const matchIdx = matches.indexOf(m)
        const isPostMode = postModeMatches[m.id] ?? false
        const tNameA = teamName(teams, m.teamA)
        const tNameB = teamName(teams, m.teamB)

        return (
          <div key={m.id} className="flex flex-col">
            <TeamMatchCard
              match={m}
              teams={teams}
              saving={saving}
              matchIdx={matchIdx}
              onChange={onChangePartai}
              onUpdateCourt={onUpdateCourt}
              onSave={onSave}
            />

            {/* Camera toggle button — sits below the card */}
            <div className="flex justify-end px-1 pt-1">
              <button
                onClick={() => setPostModeMatches((prev) => ({ ...prev, [m.id]: !prev[m.id] }))}
                className={`w-8 h-8 rounded-full flex items-center justify-center transition-colors ${
                  isPostMode ? 'bg-accent active:bg-yellow-300' : 'bg-surface border border-border-subtle active:bg-elevated'
                }`}
                aria-label="Toggle post mode"
              >
                <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke={isPostMode ? 'black' : 'currentColor'} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
                  <circle cx="12" cy="13" r="4"/>
                </svg>
              </button>
            </div>

            {/* Photo upload panel */}
            {isPostMode && (
              <div className="bg-surface border border-border-subtle rounded-lg mt-1 px-4 py-3 flex flex-col gap-2">
                {/* Team photo row */}
                <div className="flex items-center justify-between">
                  <span className="text-xs text-fg-dim">Team photo ({tNameA} vs {tNameB})</span>
                  <div className="relative">
                    <button
                      onClick={() => { activeUploadKey.current = m.id; fileInputRef.current?.click() }}
                      className="w-7 h-7 rounded-full bg-elevated border border-border-subtle flex items-center justify-center active:bg-border"
                      aria-label="Upload team photo"
                    >
                      <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
                        <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
                        <circle cx="12" cy="13" r="4"/>
                      </svg>
                    </button>
                    {teamPhotos[m.id] && (
                      <span className="absolute -top-0.5 -right-0.5 w-2 h-2 rounded-full bg-green-500 border border-surface" />
                    )}
                  </div>
                </div>

                {/* Per-partai photo rows */}
                {PARTAI_CLASSES.map(([clsA, clsB], pi) => {
                  const key = `${m.id}-${pi}`
                  const nameA = getPairName(teams, m.teamA, clsA, clsB)
                  const nameB = getPairName(teams, m.teamB, clsA, clsB)
                  return (
                    <div key={pi} className="flex items-center justify-between">
                      <span className="text-xs text-fg-dim truncate flex-1 mr-3">
                        {clsA}{clsB} · {nameA} vs {nameB}
                      </span>
                      <div className="relative shrink-0">
                        <button
                          onClick={() => { activeUploadKey.current = key; fileInputRef.current?.click() }}
                          className="w-7 h-7 rounded-full bg-elevated border border-border-subtle flex items-center justify-center active:bg-border"
                          aria-label={`Upload photo for ${clsA}${clsB}`}
                        >
                          <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
                            <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
                            <circle cx="12" cy="13" r="4"/>
                          </svg>
                        </button>
                        {partaiPhotos[key] && (
                          <span className="absolute -top-0.5 -right-0.5 w-2 h-2 rounded-full bg-green-500 border border-surface" />
                        )}
                      </div>
                    </div>
                  )
                })}

                {/* Download bar */}
                <div className="flex items-center justify-between pt-1 border-t border-border-subtle mt-1">
                  <span className="text-xs text-fg-dim">{uploadedCount(m.id)} of 4 photos</span>
                  <button
                    onClick={() => handleDownload(m)}
                    disabled={uploadedCount(m.id) === 0}
                    className="w-8 h-8 rounded-full bg-accent flex items-center justify-center active:bg-yellow-300 disabled:opacity-40"
                    aria-label="Download posts"
                  >
                    <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="black" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                      <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
                      <polyline points="7 10 12 15 17 10"/>
                      <line x1="12" y1="15" x2="12" y2="3"/>
                    </svg>
                  </button>
                </div>
              </div>
            )}
          </div>
        )
      })}

      {/* Single hidden file input shared by all upload buttons */}
      <input
        type="file"
        accept="image/jpeg,image/png,image/webp"
        className="hidden"
        ref={fileInputRef}
        onChange={async (e) => {
          const file = e.target.files?.[0]
          const key = activeUploadKey.current
          if (!file || !key) return
          const url = URL.createObjectURL(file)
          const img = new Image()
          img.onload = () => {
            URL.revokeObjectURL(url)
            // Partai keys are `${matchId}-${pi}` (e.g. "g-1-0") — two or more dashes.
            // Team photo keys are bare match IDs (e.g. "g-1") — one dash.
            const isPartai = (key.match(/-/g) ?? []).length >= 2
            if (isPartai) {
              setPartaiPhotos((prev) => ({ ...prev, [key]: img }))
            } else {
              setTeamPhotos((prev) => ({ ...prev, [key]: img }))
            }
          }
          img.onerror = () => URL.revokeObjectURL(url)
          img.src = url
          e.target.value = ''
        }}
      />
    </div>
  )
}
```

> **Note on key disambiguation:** match IDs for group matches are `g-1` through `g-9`. A key ending with `-0`, `-1`, or `-2` after a `-` + digit is a partai key. The regex `/-\d$/` matches partai keys. Team photo keys are bare match IDs like `g-1`.

- [ ] **Step 2: Build to confirm no TypeScript errors**

```bash
cd apps/web && npm run build 2>&1 | tail -20
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add apps/web/src/components/tournament/TeamGroupSchedule.tsx
git commit -m "feat: add TeamGroupSchedule component with photo upload and post export"
```

---

## Task 4: Wire into TeamTournamentPage + Final tab champion export

**Files:**
- Modify: `apps/web/src/pages/TeamTournamentPage.tsx`

- [ ] **Step 1: Add imports at the top of `TeamTournamentPage.tsx`**

Add these imports (after existing imports):
```tsx
import { useEffect, useRef, useState as useLocalState } from 'react'
import TeamGroupSchedule from '../components/tournament/TeamGroupSchedule'
import { drawMatchPost, drawTeamMatchPost, drawPositionPost, type TeamMatchPartaiRow } from '../utils/canvasPost'
import type { OverlayImages } from '../utils/canvasPost'
import { canvasToBlob, shareOrDownload } from '../utils/share'
import { loadOverlayImages } from '../utils/overlays'
import { PARTAI_CLASSES } from '../utils/teamTournament'
```

> Note: `useState` is already imported in the file — use `useLocalState` alias only if there's a naming conflict, otherwise just add to the existing import.

- [ ] **Step 2: Add Final tab photo state inside `TeamTournamentPage`**

Inside the component body, after existing state declarations, add:
```tsx
const [finalPhotos, setFinalPhotos] = useState<Record<string, HTMLImageElement>>({})
const [finalOverlays, setFinalOverlays] = useState<OverlayImages>({})
const finalFileInputRef = useRef<HTMLInputElement>(null)
const activeFinalKey = useRef<string | null>(null)

useEffect(() => {
  loadOverlayImages({
    logo: '/instagram-logo.png',
    badge: '/tournament-badge.png',
    chevrons: '/chevrons.png',
    sponsor: '/sponsor-logo.png',
  }).then(setFinalOverlays)
}, [])
```

- [ ] **Step 3: Add the champion download handler inside `TeamTournamentPage`**

First add a local helper above `handleFinalDownload` (after the `handleBuatFinal` function):
```tsx
const getFinalPairName = (teamId: string, clsA: string, clsB: string): string => {
  const team = teams.find((t) => t.id === teamId)
  const p1 = team?.players.find((p) => p.cls === clsA)?.name ?? '—'
  const p2 = team?.players.find((p) => p.cls === clsB)?.name ?? '—'
  return `${p1}/${p2}`
}
```

Then add the download handler:
```tsx
const handleFinalDownload = async () => {
  if (!finalMatch || !championName) return
  const out = teamMatchOutcome(finalMatch)
  const tNameA = teamName(teams, finalMatch.teamA)
  const tNameB = teamName(teams, finalMatch.teamB)
  const files: File[] = []

  // Per-partai final posts
  for (let pi = 0; pi < PARTAI_CLASSES.length; pi++) {
    const key = `partai-${pi}`
    const photo = finalPhotos[key]
    const p = finalMatch.partai[pi]
    if (!photo || p.scoreA === null || p.scoreB === null) continue
    const [clsA, clsB] = PARTAI_CLASSES[pi]
    const nameA = getFinalPairName(finalMatch.teamA, clsA, clsB)
    const nameB = getFinalPairName(finalMatch.teamB, clsA, clsB)
    const c = document.createElement('canvas')
    drawMatchPost(c, photo, nameA, nameB, p.scoreA, p.scoreB, `FINAL · ${clsA}${clsB}`, finalOverlays.logo, finalOverlays.badge, finalOverlays.chevrons, finalOverlays.sponsor)
    const blob = await canvasToBlob(c)
    if (blob) files.push(new File([blob], `final-${clsA}${clsB}.jpg`, { type: 'image/jpeg' }))
  }

  // Team summary post
  const teamPhoto = finalPhotos['team']
  if (teamPhoto) {
    const partaiRows: TeamMatchPartaiRow[] = PARTAI_CLASSES.map(([clsA, clsB], pi) => ({
      tier: `${clsA}${clsB}`,
      nameA: getFinalPairName(finalMatch.teamA, clsA, clsB),
      nameB: getFinalPairName(finalMatch.teamB, clsA, clsB),
      scoreA: finalMatch.partai[pi].scoreA,
      scoreB: finalMatch.partai[pi].scoreB,
    }))
    const c = document.createElement('canvas')
    drawTeamMatchPost(c, teamPhoto, tNameA, tNameB, out.aWins, out.bWins, partaiRows, 'FINAL', finalOverlays.logo, finalOverlays.chevrons, finalOverlays.sponsor)
    const blob = await canvasToBlob(c)
    if (blob) files.push(new File([blob], 'final-summary.jpg', { type: 'image/jpeg' }))
  }

  // Champion post
  const champPhoto = finalPhotos['champion']
  if (champPhoto) {
    const c = document.createElement('canvas')
    drawPositionPost(c, champPhoto, '🏆 CHAMPION', championName, finalOverlays.logo, finalOverlays.chevrons, finalOverlays.sponsor, finalOverlays.badge)
    const blob = await canvasToBlob(c)
    if (blob) files.push(new File([blob], 'champion.jpg', { type: 'image/jpeg' }))
  }

  if (files.length > 0) await shareOrDownload(files, `Final · ${championName}`)
}
```

- [ ] **Step 4: Replace jadwal tab JSX with `<TeamGroupSchedule>`**

Find the `{tab === 'jadwal' && (` block and replace its contents:

**Before:**
```tsx
{tab === 'jadwal' && (
  <>
    {groupMatches.length === 0 && (
      <button
        onClick={handleUndian}
        disabled={publish.isPending}
        className="w-full py-3 rounded-lg bg-accent text-slate-950 font-bold text-sm disabled:opacity-40"
      >
        Group Draw (match day)
      </button>
    )}
    {groupMatches.map((m, mi) => (
      <MatchCard
        key={m.id}
        match={m}
        teams={teams}
        saving={publish.isPending}
        onChange={(_, pi, patch) => updatePartai(mi, pi, patch)}
        onUpdateCourt={(matchIdx, courtIdx, name) => updateCourt(matchIdx, courtIdx, name)}
        matchIdx={mi}
        onSave={() => localMatches && saveMatches(localMatches)}
      />
    ))}
  </>
)}
```

**After:**
```tsx
{tab === 'jadwal' && (
  <TeamGroupSchedule
    teams={teams}
    matches={matches}
    saving={publish.isPending}
    onChangePartai={(matchIdx, pi, patch) => updatePartai(matchIdx, pi, patch)}
    onUpdateCourt={updateCourt}
    onSave={() => localMatches && saveMatches(localMatches)}
    onDraw={handleUndian}
  />
)}
```

- [ ] **Step 5: Add Final tab photo export UI**

Inside the `{tab === 'final' && ...}` block, after the existing champion banner and `<TeamMatchCard>`, add:

```tsx
{/* Photo export section — only shown when final match exists */}
{finalMatch && (
  <div className="bg-surface border border-border-subtle rounded-lg px-4 py-3 flex flex-col gap-2">
    <p className="text-xs text-fg-dim uppercase tracking-wider">Export Posts</p>

    {/* Team summary photo */}
    <div className="flex items-center justify-between">
      <span className="text-xs text-fg-dim">Team summary photo</span>
      <div className="relative">
        <button
          onClick={() => { activeFinalKey.current = 'team'; finalFileInputRef.current?.click() }}
          className="w-7 h-7 rounded-full bg-elevated border border-border-subtle flex items-center justify-center"
          aria-label="Upload team summary photo"
        >
          <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
            <circle cx="12" cy="13" r="4"/>
          </svg>
        </button>
        {finalPhotos['team'] && <span className="absolute -top-0.5 -right-0.5 w-2 h-2 rounded-full bg-green-500 border border-surface" />}
      </div>
    </div>

    {/* Per-partai photos */}
    {PARTAI_CLASSES.map(([clsA, clsB], pi) => (
      <div key={pi} className="flex items-center justify-between">
        <span className="text-xs text-fg-dim">{clsA}{clsB} partai photo</span>
        <div className="relative">
          <button
            onClick={() => { activeFinalKey.current = `partai-${pi}`; finalFileInputRef.current?.click() }}
            className="w-7 h-7 rounded-full bg-elevated border border-border-subtle flex items-center justify-center"
            aria-label={`Upload ${clsA}${clsB} photo`}
          >
            <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
              <circle cx="12" cy="13" r="4"/>
            </svg>
          </button>
          {finalPhotos[`partai-${pi}`] && <span className="absolute -top-0.5 -right-0.5 w-2 h-2 rounded-full bg-green-500 border border-surface" />}
        </div>
      </div>
    ))}

    {/* Champion photo — only if champion determined */}
    {championName && (
      <div className="flex items-center justify-between">
        <span className="text-xs text-fg-dim">Champion photo</span>
        <div className="relative">
          <button
            onClick={() => { activeFinalKey.current = 'champion'; finalFileInputRef.current?.click() }}
            className="w-7 h-7 rounded-full bg-elevated border border-border-subtle flex items-center justify-center"
            aria-label="Upload champion photo"
          >
            <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
              <circle cx="12" cy="13" r="4"/>
            </svg>
          </button>
          {finalPhotos['champion'] && <span className="absolute -top-0.5 -right-0.5 w-2 h-2 rounded-full bg-green-500 border border-surface" />}
        </div>
      </div>
    )}

    {/* Download bar */}
    <div className="flex items-center justify-between pt-1 border-t border-border-subtle mt-1">
      <span className="text-xs text-fg-dim">{Object.keys(finalPhotos).length} of {championName ? 5 : 4} photos</span>
      <button
        onClick={handleFinalDownload}
        disabled={Object.keys(finalPhotos).length === 0}
        className="w-8 h-8 rounded-full bg-accent flex items-center justify-center active:bg-yellow-300 disabled:opacity-40"
        aria-label="Download final posts"
      >
        <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="black" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
          <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
          <polyline points="7 10 12 15 17 10"/>
          <line x1="12" y1="15" x2="12" y2="3"/>
        </svg>
      </button>
    </div>
  </div>
)}

{/* Hidden file input for final tab */}
<input
  type="file"
  accept="image/jpeg,image/png,image/webp"
  className="hidden"
  ref={finalFileInputRef}
  onChange={async (e) => {
    const file = e.target.files?.[0]
    const key = activeFinalKey.current
    if (!file || !key) return
    const url = URL.createObjectURL(file)
    const img = new Image()
    img.onload = () => { URL.revokeObjectURL(url); setFinalPhotos((prev) => ({ ...prev, [key]: img })) }
    img.onerror = () => URL.revokeObjectURL(url)
    img.src = url
    e.target.value = ''
  }}
/>
```

- [ ] **Step 6: Build to confirm no TypeScript errors**

```bash
cd apps/web && npm run build 2>&1 | tail -20
```

Expected: build succeeds with no errors.

- [ ] **Step 7: Run regression tests**

```bash
cd apps/web && npm run check:regression 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 8: Smoke test in browser**

```bash
cd apps/web && npm run dev
```

Open the Team Tournament page. Verify:
1. Schedule tab renders group matches as before (no regression)
2. Camera icon appears below each group match card
3. Tapping camera shows the photo upload panel with 4 rows (1 team + 3 partai) + download button
4. Uploading a photo shows a green dot
5. Download button is disabled until at least 1 photo is uploaded
6. Final tab shows the "Export Posts" panel below the MatchCard
7. Upload buttons work; download triggers share/download sheet

- [ ] **Step 9: Commit**

```bash
git add apps/web/src/pages/TeamTournamentPage.tsx
git commit -m "feat: wire team tournament photo post export into schedule and final tabs"
```
