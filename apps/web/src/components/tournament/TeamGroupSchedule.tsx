// apps/web/src/components/tournament/TeamGroupSchedule.tsx
import { useRef } from 'react'
import {
  teamMatchOutcome,
  teamName,
  teamLogoPath,
  PARTAI_CLASSES,
  type TeamMatch,
  type TeamInfo,
} from '../../utils/teamTournament'
import TeamMatchCard from './TeamMatchCard'
import { drawMatchPost, drawTeamMatchPost, loadImage, type TeamMatchPartaiRow } from '../../utils/canvasPost'
import { canvasToBlob, shareOrDownload } from '../../utils/share'

interface TeamGroupScheduleProps {
  teams: TeamInfo[]
  matches: TeamMatch[]
  saving: boolean
  overlays: Record<string, HTMLImageElement | undefined>
  partaiPhotos: Record<string, HTMLImageElement>
  postModeMatches: Record<string, boolean>
  onChangePartai: (matchIdx: number, partaiIdx: number, patch: Partial<{ scoreA: number | null; scoreB: number | null }>) => void
  onUpdateCourt: (matchIdx: number, courtIdx: number, name: string) => void
  onSave: () => void
  onDraw: () => void
  onSetPartaiPhoto: (key: string, img: HTMLImageElement) => void
  onSetPostMode: (matchId: string, on: boolean) => void
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
  overlays,
  partaiPhotos,
  postModeMatches,
  onChangePartai,
  onUpdateCourt,
  onSave,
  onDraw,
  onSetPartaiPhoto,
  onSetPostMode,
}: TeamGroupScheduleProps) {
  const groupMatches = matches.filter((m) => m.phase === 'group')

  const fileInputRef = useRef<HTMLInputElement>(null)
  const activeUploadKey = useRef<string | null>(null)

  const uploadedCount = (matchId: string): number => {
    let count = 0
    for (let i = 0; i < PARTAI_CLASSES.length; i++) {
      if (partaiPhotos[`${matchId}-${i}`]) count++
    }
    return count
  }

  const handleDownload = async (m: TeamMatch) => {
    const out = teamMatchOutcome(m)
    const tNameA = teamName(teams, m.teamA)
    const tNameB = teamName(teams, m.teamB)
    const slug = `${tNameA.toLowerCase().replace(/\s+/g, '-')}-vs-${tNameB.toLowerCase().replace(/\s+/g, '-')}`
    const files: File[] = []

    const [teamALogoImg, teamBLogoImg] = await Promise.all([
      teamLogoPath(tNameA) ? loadImage(teamLogoPath(tNameA)!).catch(() => undefined) : Promise.resolve(undefined),
      teamLogoPath(tNameB) ? loadImage(teamLogoPath(tNameB)!).catch(() => undefined) : Promise.resolve(undefined),
    ])

    for (let pi = 0; pi < PARTAI_CLASSES.length; pi++) {
      const key = `${m.id}-${pi}`
      const photo = partaiPhotos[key]
      const p = m.partai[pi]
      if (!photo || p.scoreA === null || p.scoreB === null) continue
      const [clsA, clsB] = PARTAI_CLASSES[pi]
      const nameA = getPairName(teams, m.teamA, clsA, clsB)
      const nameB = getPairName(teams, m.teamB, clsA, clsB)
      const c = document.createElement('canvas')
      drawMatchPost(c, photo, nameA, nameB, p.scoreA, p.scoreB, `GROUP MATCH · ${clsA}${clsB}`, overlays.logo, overlays.badge, overlays.chevrons, overlays.sponsor, overlays.cardLogo, teamALogoImg, teamBLogoImg, 'MAJADU 1\u02E2\u1D57 ANNIVERSARY  \u2022  MAJADU 1\u02E2\u1D57 ANNIVERSARY')
      const blob = await canvasToBlob(c)
      if (blob) files.push(new File([blob], `${slug}-${clsA}${clsB}.jpg`, { type: 'image/jpeg' }))
    }

    // Summary post — no photo needed, always generated
    const partaiRows: TeamMatchPartaiRow[] = PARTAI_CLASSES.map(([clsA, clsB], pi) => ({
      tier: `${clsA}${clsB}`,
      nameA: getPairName(teams, m.teamA, clsA, clsB),
      nameB: getPairName(teams, m.teamB, clsA, clsB),
      scoreA: m.partai[pi].scoreA,
      scoreB: m.partai[pi].scoreB,
    }))
    const summaryCanvas = document.createElement('canvas')
    drawTeamMatchPost(summaryCanvas, tNameA, tNameB, out.aWins, out.bWins, partaiRows, 'GROUP STAGE', overlays.summaryBg, overlays.logo, overlays.sponsor, overlays.cardLogo, teamALogoImg, teamBLogoImg)
    const summaryBlob = await canvasToBlob(summaryCanvas)
    if (summaryBlob) files.push(new File([summaryBlob], `${slug}-summary.jpg`, { type: 'image/jpeg' }))

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

        return (
          <TeamMatchCard
            key={m.id}
            match={m}
            teams={teams}
            saving={saving}
            matchIdx={matchIdx}
            onChange={onChangePartai}
            onUpdateCourt={onUpdateCourt}
            onSave={onSave}
            postProps={{
              isPostMode,
              onTogglePostMode: () => onSetPostMode(m.id, !isPostMode),
              partaiPhotos: PARTAI_CLASSES.map((_, pi) => partaiPhotos[`${m.id}-${pi}`]),
              onUploadPartai: (pi) => { activeUploadKey.current = `${m.id}-${pi}`; fileInputRef.current?.click() },
              onDownload: () => handleDownload(m),
              uploadedCount: uploadedCount(m.id),
            }}
          />
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
            onSetPartaiPhoto(key, img)
          }
          img.onerror = () => URL.revokeObjectURL(url)
          img.src = url
          e.target.value = ''
        }}
      />
    </div>
  )
}
