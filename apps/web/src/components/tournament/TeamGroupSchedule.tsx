// apps/web/src/components/tournament/TeamGroupSchedule.tsx
import {
  buildTeamMatchFiles,
  teamName,
  PARTAI_CLASSES,
  type TeamMatch,
  type TeamInfo,
} from '../../utils/teamTournament'
import { useImageUploadMap } from '../../hooks/useImageUploadMap'
import TeamMatchCard from './TeamMatchCard'
import { shareOrDownload } from '../../utils/share'

interface TeamGroupScheduleProps {
  teams: TeamInfo[]
  matches: TeamMatch[]
  saving: boolean
  overlays: Record<string, HTMLImageElement | undefined>
  partaiPhotos: Record<string, HTMLImageElement>
  postModeMatches: Record<string, boolean>
  onChangePartai: (matchIdx: number, partaiIdx: number, patch: Partial<{ scoreA: number | null; scoreB: number | null }>) => void
  onUpdateCourt: (matchIdx: number, name: string) => void
  dirtyByMatchId: Record<string, boolean>
  onSave: () => void
  onDraw: () => void
  onSetPartaiPhoto: (key: string, img: HTMLImageElement) => void
  onSetPostMode: (matchId: string, on: boolean) => void
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
  dirtyByMatchId,
  onSave,
  onDraw,
  onSetPartaiPhoto,
  onSetPostMode,
}: TeamGroupScheduleProps) {
  const groupMatches = matches.filter((m) => m.phase === 'group')

  const { fileInputRef, openUpload, onFileChange } = useImageUploadMap(onSetPartaiPhoto)

  const uploadedCount = (matchId: string): number => {
    let count = 0
    for (let i = 0; i < PARTAI_CLASSES.length; i++) {
      if (partaiPhotos[`${matchId}-${i}`]) count++
    }
    return count
  }

  const handleDownload = async (m: TeamMatch) => {
    const tNameA = teamName(teams, m.teamA)
    const tNameB = teamName(teams, m.teamB)
    const slug = `${tNameA.toLowerCase().replace(/\s+/g, '-')}-vs-${tNameB.toLowerCase().replace(/\s+/g, '-')}`

    const { files } = await buildTeamMatchFiles({
      teams,
      match: m,
      partaiPhotos,
      photoKey: (pi) => `${m.id}-${pi}`,
      overlays,
      matchSubtitle: 'GROUP MATCH',
      summarySubtitle: 'GROUP STAGE',
      filePrefix: slug,
    })

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
            dirty={dirtyByMatchId[m.id] ?? false}
            onChange={onChangePartai}
            onUpdateCourt={onUpdateCourt}
            onSave={onSave}
            postProps={{
              isPostMode,
              onTogglePostMode: () => onSetPostMode(m.id, !isPostMode),
              partaiPhotos: PARTAI_CLASSES.map((_, pi) => partaiPhotos[`${m.id}-${pi}`]),
              onUploadPartai: (pi) => openUpload(`${m.id}-${pi}`),
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
        onChange={onFileChange}
      />
    </div>
  )
}
