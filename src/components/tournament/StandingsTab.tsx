import { useMemo } from 'react'
import { useTournamentStore } from '../../store/tournament'
import { computeGroupStandings } from '../../utils/tournament'
import type { TournamentMatch, GroupId } from '../../store/tournament'

const GROUP_IDS: GroupId[] = ['A', 'B', 'C', 'D']
const STAGE_LABEL = ['🥇 Champion', '🥈 Runner-up', '🥉 3rd Place', '4th Place', 'QF Exit', 'Group Stage']

function stageRank(pairId: string, matches: TournamentMatch[]): number {
  const final = matches.find((m) => m.id === 'final-1')
  const third = matches.find((m) => m.id === '3rd-1')
  const w = (m?: TournamentMatch) =>
    m?.scoreA != null ? (m.scoreA > m.scoreB! ? m.pairAId : m.pairBId) : null

  if (w(final) === pairId) return 0
  if (final?.pairAId === pairId || final?.pairBId === pairId) return 1
  if (w(third) === pairId) return 2
  if (third?.pairAId === pairId || third?.pairBId === pairId) return 3

  const qfIds = ['qf-1', 'qf-2', 'qf-3', 'qf-4']
  if (matches.some((m) => qfIds.includes(m.id) && (m.pairAId === pairId || m.pairBId === pairId)))
    return 4

  return 5
}

export default function StandingsTab() {
  const pairs = useTournamentStore((s) => s.pairs)
  const groups = useTournamentStore((s) => s.groups)
  const matches = useTournamentStore((s) => s.matches)

  const getPairName = (id: string) => pairs.find((p) => p.id === id)?.name ?? id

  const allStandings = useMemo(
    () => GROUP_IDS.flatMap((g) => computeGroupStandings(g, groups[g], matches)),
    [groups, matches]
  )

  const ranked = useMemo(
    () =>
      [...pairs].sort((a, b) => {
        const ra = stageRank(a.id, matches)
        const rb = stageRank(b.id, matches)
        if (ra !== rb) return ra - rb
        const sa = allStandings.find((s) => s.pairId === a.id)
        const sb = allStandings.find((s) => s.pairId === b.id)
        return (sb?.pointDiff ?? 0) - (sa?.pointDiff ?? 0)
      }),
    [pairs, matches, allStandings]
  )

  if (!matches.length) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-16 text-center">
        <span className="text-4xl">📊</span>
        <p className="text-slate-400 text-sm">Standings will appear once matches are played.</p>
      </div>
    )
  }

  const top3 = [ranked[1], ranked[0], ranked[2]]
  const top3Emojis = ['🥈', '🏆', '🥉']
  const top3Sizes = ['text-2xl', 'text-3xl', 'text-2xl']
  const top3MTop = ['', '-mt-4', '']

  return (
    <div className="space-y-4">
      {/* Podium */}
      <div className="bg-slate-800 rounded-2xl p-4 flex justify-around items-end">
        {top3.map((p, i) => (
          <div key={p?.id ?? i} className={`text-center ${top3MTop[i]}`}>
            <div className={top3Sizes[i]}>{top3Emojis[i]}</div>
            <div className="text-xs text-slate-300 mt-1 font-medium max-w-[80px] truncate">
              {p ? getPairName(p.id) : 'TBD'}
            </div>
          </div>
        ))}
      </div>

      {/* Full ranking */}
      <div className="bg-slate-800 rounded-xl overflow-hidden">
        <div className="px-4 py-2 border-b border-slate-700 text-xs text-slate-500 font-semibold">
          Full Rankings
        </div>
        {ranked.map((pair, i) => {
          const rank = stageRank(pair.id, matches)
          const stats = allStandings.find((s) => s.pairId === pair.id)
          return (
            <div
              key={pair.id}
              className="flex items-center gap-3 px-4 py-3 border-b border-slate-700/50 last:border-0"
            >
              <span className="text-slate-500 font-bold w-5 text-sm shrink-0">{i + 1}</span>
              <div className="flex-1 min-w-0">
                <div className="text-sm text-slate-200 truncate">{getPairName(pair.id)}</div>
                <div className="text-[10px] text-slate-500 mt-0.5">
                  {STAGE_LABEL[Math.min(rank, 5)]}
                </div>
              </div>
              {stats && (
                <div className="text-right shrink-0">
                  <div
                    className={`text-xs font-medium ${
                      stats.pointDiff > 0
                        ? 'text-green-400'
                        : stats.pointDiff < 0
                        ? 'text-red-400'
                        : 'text-slate-500'
                    }`}
                  >
                    {stats.pointDiff > 0 ? `+${stats.pointDiff}` : stats.pointDiff || '—'}
                  </div>
                  <div className="text-[10px] text-slate-600">
                    {stats.wins}W {stats.losses}L
                  </div>
                </div>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}
