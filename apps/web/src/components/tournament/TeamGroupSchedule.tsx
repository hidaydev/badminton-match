// apps/web/src/components/tournament/TeamGroupSchedule.tsx
import { useEffect, useRef, useState } from 'react'
import {
  teamMatchOutcome,
  teamName,
  PARTAI_CLASSES,
  type TeamMatch,
  type TeamInfo,
} from '../../utils/teamTournament'
import TeamMatchCard from './TeamMatchCard'
import { drawMatchPost, drawTeamMatchPost, type TeamMatchPartaiRow } from '../../utils/canvasPost'
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

  const [postModeMatches, setPostModeMatches] = useState<Record<string, boolean>>({})
  const [teamPhotos, setTeamPhotos] = useState<Record<string, HTMLImageElement>>({})
  const [partaiPhotos, setPartaiPhotos] = useState<Record<string, HTMLImageElement>>({})
  const [overlays, setOverlays] = useState<Record<string, HTMLImageElement | undefined>>({})
  const fileInputRef = useRef<HTMLInputElement>(null)
  const activeUploadKey = useRef<string | null>(null)

  useEffect(() => {
    loadOverlayImages({
      logo: '/instagram-logo.png',
      badge: '/tournament-badge.png',
      chevrons: '/chevrons.png',
      sponsor: '/sponsor-logo.png',
    }).then((imgs) => setOverlays(imgs as Record<string, HTMLImageElement | undefined>))
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

            {isPostMode && (
              <div className="bg-surface border border-border-subtle rounded-lg mt-1 px-4 py-3 flex flex-col gap-2">
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
