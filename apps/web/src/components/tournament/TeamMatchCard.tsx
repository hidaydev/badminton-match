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
