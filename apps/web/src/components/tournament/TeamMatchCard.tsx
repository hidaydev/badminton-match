// apps/web/src/components/tournament/TeamMatchCard.tsx
import { teamMatchOutcome, teamTarget, PARTAI_CLASSES, teamName, type TeamMatch, type TeamInfo } from '../../utils/teamTournament'

interface PostProps {
  isPostMode: boolean
  onTogglePostMode: () => void
  partaiPhotos: (HTMLImageElement | undefined)[]
  teamPhoto: HTMLImageElement | undefined
  onUploadPartai: (pi: number) => void
  onUploadTeam: () => void
  onDownload: () => void
  uploadedCount: number
}

const CameraIcon = ({ size = 13, stroke = 'currentColor' }: { size?: number; stroke?: string }) => (
  <svg xmlns="http://www.w3.org/2000/svg" width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={stroke} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
    <circle cx="12" cy="13" r="4"/>
  </svg>
)

export default function TeamMatchCard({
  match,
  teams,
  saving,
  matchIdx,
  onChange,
  onUpdateCourt,
  onSave,
  postProps,
}: {
  match: TeamMatch
  teams: TeamInfo[]
  saving: boolean
  matchIdx: number
  onChange: (matchIdx: number, partaiIdx: number, patch: Partial<{ scoreA: number | null; scoreB: number | null }>) => void
  onUpdateCourt: (matchIdx: number, courtIdx: number, name: string) => void
  onSave: () => void
  postProps?: PostProps
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
      {/* Header */}
      <div className="flex items-center justify-between px-4 py-2 border-b border-border-subtle">
        <span className="text-xs text-fg-dim uppercase tracking-wider">{label}</span>
        <div className="flex items-center gap-2">
          {dirty && (
            <span className="text-[11px] text-fg-dim">
              {out.complete ? `${out.aWins}-${out.bWins}` : 'incomplete'}
            </span>
          )}
          {postProps && (
            <button
              onClick={postProps.onTogglePostMode}
              className={`w-7 h-7 rounded-full flex items-center justify-center transition-colors ${
                postProps.isPostMode ? 'bg-accent' : 'bg-elevated border border-border-subtle'
              }`}
              aria-label="Toggle post mode"
            >
              <CameraIcon stroke={postProps.isPostMode ? 'black' : 'currentColor'} />
            </button>
          )}
        </div>
      </div>

      {/* Partai rows */}
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
              {/* Inline camera icon per partai (post mode) */}
              {postProps?.isPostMode && (
                <div className="relative shrink-0">
                  <button
                    onClick={() => postProps.onUploadPartai(pi)}
                    className="w-6 h-6 rounded-full bg-elevated border border-border-subtle flex items-center justify-center active:bg-border"
                    aria-label={`Upload photo for ${clsA}${clsB}`}
                  >
                    <CameraIcon size={11} />
                  </button>
                  {postProps.partaiPhotos[pi] && (
                    <span className="absolute -top-0.5 -right-0.5 w-2 h-2 rounded-full bg-green-500 border border-surface" />
                  )}
                </div>
              )}
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

      {/* Footer: Save + post-mode team photo + download */}
      <div className="px-4 pb-3 flex items-center gap-2">
        <button
          onClick={onSave}
          disabled={saving || !dirty}
          className="flex-1 py-2 rounded-lg bg-accent/15 border border-accent/30 text-accent text-sm font-bold disabled:opacity-40"
        >
          {saving ? 'Saving…' : 'Save'}
        </button>

        {postProps?.isPostMode && (
          <>
            <div className="relative shrink-0">
              <button
                onClick={postProps.onUploadTeam}
                className="w-9 h-9 rounded-lg bg-elevated border border-border-subtle flex items-center justify-center active:bg-border"
                aria-label="Upload team photo"
              >
                <CameraIcon />
              </button>
              {postProps.teamPhoto && (
                <span className="absolute -top-0.5 -right-0.5 w-2 h-2 rounded-full bg-green-500 border border-surface" />
              )}
            </div>
            <button
              onClick={postProps.onDownload}
              disabled={postProps.uploadedCount === 0}
              className="w-9 h-9 rounded-lg bg-accent flex items-center justify-center active:bg-yellow-300 disabled:opacity-40 shrink-0"
              aria-label="Download posts"
            >
              <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="black" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
                <polyline points="7 10 12 15 17 10"/>
                <line x1="12" y1="15" x2="12" y2="3"/>
              </svg>
            </button>
          </>
        )}
      </div>
    </div>
  )
}
