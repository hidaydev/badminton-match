import { useMemo } from 'react'
import { computeGroupStandings, GROUP_IDS, QF_IDS, FINAL_ID, THIRD_PLACE_ID } from '../../utils/tournament'
import type { TournamentMatch, TournamentPair, GroupId } from '../../utils/tournament'

const STAGE_LABEL = ['Champion', 'Runner-up', '3rd Place', '4th Place', 'QF Exit', 'Group Stage']

function stageRank(pairId: string, matches: TournamentMatch[]): number {
  const final = matches.find((m) => m.id === FINAL_ID)
  const third = matches.find((m) => m.id === THIRD_PLACE_ID)
  const w = (m?: TournamentMatch) =>
    m && m.scoreA != null && m.scoreB != null ? (m.scoreA > m.scoreB ? m.pairAId : m.pairBId) : null

  if (w(final) === pairId) return 0
  if (final?.pairAId === pairId || final?.pairBId === pairId) return 1
  if (w(third) === pairId) return 2
  if (third?.pairAId === pairId || third?.pairBId === pairId) return 3

  const qfIds: readonly string[] = QF_IDS
  if (matches.some((m) => qfIds.includes(m.id) && (m.pairAId === pairId || m.pairBId === pairId)))
    return 4

  return 5
}

interface StandingsTabProps {
  pairs: TournamentPair[]
  groups: Record<GroupId, string[]>
  matches: TournamentMatch[]
}

export default function StandingsTab({ pairs, groups, matches }: StandingsTabProps) {
  const getPairName = (id: string) => pairs.find((p) => p.id === id)?.name ?? id

  const allStandings = useMemo(
    () => GROUP_IDS.flatMap((g) => computeGroupStandings(g, groups[g], matches)),
    [groups, matches],
  )

  const totalRecord = useMemo(() => {
    const rec: Record<string, { wins: number; losses: number }> = {}
    for (const m of matches) {
      if (m.scoreA === null || m.scoreB === null || !m.pairAId || !m.pairBId) continue
      rec[m.pairAId] ??= { wins: 0, losses: 0 }
      rec[m.pairBId] ??= { wins: 0, losses: 0 }
      if (m.scoreA > m.scoreB) { rec[m.pairAId].wins++; rec[m.pairBId].losses++ }
      else { rec[m.pairBId].wins++; rec[m.pairAId].losses++ }
    }
    return rec
  }, [matches])

  const ranked = useMemo(
    () =>
      [...pairs].sort((a, b) => {
        const ra = stageRank(a.id, matches)
        const rb = stageRank(b.id, matches)
        if (ra !== rb) return ra - rb
        const sa = allStandings.find((s) => s.pairId === a.id)
        const sb = allStandings.find((s) => s.pairId === b.id)
        return (sb?.diff ?? 0) - (sa?.diff ?? 0)
      }),
    [pairs, matches, allStandings]
  )

  if (!matches.length) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-16 text-center">
        <span className="text-4xl">📊</span>
        <p className="text-fg-dim text-sm">Standings will appear once matches are played.</p>
      </div>
    )
  }

  const top3 = [
    {
      p: ranked[1],
      rank: '2',
      badgeBg: 'bg-gradient-to-b from-slate-200/20 to-slate-400/5',
      badgeBorder: 'border-slate-300/40 shadow-[0_0_12px_rgba(199,204,209,0.2)]',
      cls: 'text-slate-200',
      size: 'text-xl',
      circleSize: 'w-10 h-10',
      mt: '',
      isChamp: false,
    },
    {
      p: ranked[0],
      rank: '1',
      badgeBg: 'bg-gradient-to-b from-yellow-300/25 to-yellow-600/10',
      badgeBorder: 'border-accent/60 shadow-[0_0_16px_rgba(227,179,65,0.35)]',
      cls: 'text-accent',
      size: 'text-2xl',
      circleSize: 'w-13 h-13',
      mt: '-mt-4',
      isChamp: true,
    },
    {
      p: ranked[2],
      rank: '3',
      badgeBg: 'bg-gradient-to-b from-[#e0985c]/20 to-[#713b16]/10',
      badgeBorder: 'border-[#b36d33]/50 shadow-[0_0_12px_rgba(192,133,82,0.2)]',
      cls: 'text-[#e0985c]',
      size: 'text-xl',
      circleSize: 'w-10 h-10',
      mt: '',
      isChamp: false,
    },
  ]

  return (
    <div className="space-y-4">
      {/* Podium */}
      <div className="bg-surface border border-border-subtle rounded-xl p-4 flex justify-around items-end shadow-xs">
        {top3.map(({ p, rank, badgeBg, badgeBorder, cls, size, circleSize, mt, isChamp }) => (
          <div key={p?.id ?? rank} className={`flex flex-col items-center text-center ${mt}`}>
            <div className={`flex items-center justify-center rounded-full border ${badgeBg} ${badgeBorder} ${circleSize} mb-1`}>
              <span className={`${size} font-bold font-sans ${cls}`}>
                {rank}
              </span>
            </div>
            <div className={`text-xs mt-1 font-medium max-w-24 truncate ${isChamp ? 'text-fg text-sm font-semibold' : 'text-fg-dim'}`}>
              {p ? getPairName(p.id) : 'TBD'}
            </div>
          </div>
        ))}
      </div>

      {/* Full ranking */}
      <div className="bg-surface border border-border-subtle rounded-xl overflow-hidden shadow-xs">
        <div className="px-4 py-2.5 border-b border-border-subtle text-xs text-fg-dim font-semibold flex items-center justify-between">
          <span>Full Leaderboard</span>
        </div>
        {ranked.map((pair, i) => {
          const rank = stageRank(pair.id, matches)
          const rec = totalRecord[pair.id] ?? { wins: 0, losses: 0 }
          const isTop3 = i < 3
          return (
            <div
              key={pair.id}
              className="flex items-center gap-3 px-4 py-3 border-b border-border-subtle last:border-0 hover:bg-elevated/40 transition-colors"
            >
              <span className={`font-mono font-bold w-5 text-sm shrink-0 ${isTop3 ? (i === 0 ? 'text-accent' : i === 1 ? 'text-slate-200' : 'text-[#e0985c]') : 'text-fg-dim'}`}>
                {i + 1}
              </span>
              <div className="flex-1 min-w-0">
                <div className="text-sm text-fg font-medium truncate">{getPairName(pair.id)}</div>
                <div className="text-[10px] text-fg-dim mt-0.5">
                  {STAGE_LABEL[Math.min(rank, 5)]}
                </div>
              </div>
              <div className="text-right shrink-0">
                <span className="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-md bg-elevated border border-border-subtle font-mono text-[11px]">
                  <span className="text-success font-semibold">{rec.wins}W</span>
                  <span className="text-border">·</span>
                  <span className="text-error font-semibold">{rec.losses}L</span>
                </span>
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}
