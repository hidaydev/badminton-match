import { useState } from 'react'
import { computeGroupStandings, GROUP_COURTS } from '../../utils/tournament'
import type { GroupId, TournamentMatch, TournamentPair } from '../../utils/tournament'
import ScoreModal from './ScoreModal'

const GROUP_IDS: GroupId[] = ['A', 'B', 'C', 'D']

interface Props {
  pairs: TournamentPair[]
  groups: Record<GroupId, string[]>
  matches: TournamentMatch[]
  onSetMatchScore: (matchId: string, scoreA: number, scoreB: number) => void
  onResetGroups: () => void
  onRegeneratePics: () => void
  isRegeneratingPics: boolean
  onOpenModal: () => void
  isFetching: boolean
  refetch: () => Promise<unknown>
}

export default function GroupMatches({ pairs, groups, matches, onSetMatchScore, onResetGroups, onRegeneratePics, isRegeneratingPics, onOpenModal, isFetching, refetch }: Props) {
  const [activeMatchId, setActiveMatchId] = useState<string | null>(null)
  const activeMatch = activeMatchId ? (matches.find((m) => m.id === activeMatchId) ?? null) : null

  const getPairName = (id: string | null) =>
    id ? (pairs.find((p) => p.id === id)?.name ?? id) : 'TBD'

  return (
    <div className="space-y-4">
      <div className="flex justify-end gap-3">
        <button
          onClick={() => {
            if (confirm('Reassign scoring PICs? Current assignments will be replaced.')) onRegeneratePics()
          }}
          disabled={isRegeneratingPics}
          className="text-xs text-slate-500 hover:text-slate-300 underline disabled:opacity-50"
        >
          {isRegeneratingPics ? 'Regenerating…' : 'Regenerate PICs'}
        </button>
        <button
          onClick={() => {
            if (confirm('Reset group assignment? All scores will be lost.')) onResetGroups()
          }}
          className="text-xs text-slate-500 hover:text-slate-300 underline"
        >
          Reset groups
        </button>
      </div>

      {GROUP_IDS.map((g) => {
        const groupMatches = matches.filter((m) => m.phase === 'group' && m.groupId === g)
        const standings = computeGroupStandings(g, groups[g], matches)

        return (
          <div key={g} className="bg-slate-800 rounded-xl overflow-hidden">
            {/* Group header */}
            <div className="px-4 py-2 flex justify-between items-center border-b border-yellow-500/30">
              <span className="text-yellow-300 font-bold text-sm">GROUP {g}</span>
              <span className="text-yellow-600 text-xs">Court {GROUP_COURTS[g]}</span>
            </div>

            {/* Match rows */}
            <div className="divide-y divide-slate-700/50">
              {groupMatches.map((m) => (
                <button
                  key={m.id}
                  onClick={() => { onOpenModal(); setActiveMatchId(m.id) }}
                  className="w-full flex items-center px-4 py-3 hover:bg-slate-700/50 active:bg-slate-600/60 active:scale-[0.98] transition-transform duration-75 text-left gap-2"
                >
                  <span className="text-xs text-slate-300 flex-1 truncate">{getPairName(m.pairAId)}</span>
                  <div className="shrink-0 min-w-[56px] flex flex-col items-center">
                    <span className="text-xs font-bold text-yellow-400 bg-slate-900 rounded-md px-2 py-1">
                      {m.scoreA !== null ? `${m.scoreA}–${m.scoreB}` : '—'}
                    </span>
                    {m.picName && (
                      <span className="text-[9px] text-slate-500 mt-0.5 leading-none">{m.picName}</span>
                    )}
                  </div>
                  <span className="text-xs text-slate-300 flex-1 text-right truncate">{getPairName(m.pairBId)}</span>
                </button>
              ))}
            </div>

            {/* Mini standings */}
            <div className="border-t border-slate-700 px-4 py-2">
              <div className="grid grid-cols-[1.5rem_1fr_1.5rem_1.5rem_2.5rem_0.75rem] text-[10px] text-slate-600 mb-1 px-1 gap-x-2">
                <span>#</span><span></span>
                <span className="text-center">W</span>
                <span className="text-center">L</span>
                <span className="text-center">+/-</span>
                <span></span>
              </div>
              {standings.map((row, i) => (
                <div
                  key={row.pairId}
                  className={`grid grid-cols-[1.5rem_1fr_1.5rem_1.5rem_2.5rem_0.75rem] items-center py-1 px-1 rounded gap-x-2 text-xs ${i < 2 ? 'bg-yellow-400/[0.06]' : ''}`}
                >
                  <span className={`font-bold ${i < 2 ? 'text-yellow-100' : 'text-slate-600'}`}>{i + 1}</span>
                  <span className={`truncate font-medium ${i < 2 ? 'text-yellow-100' : 'text-slate-400'}`}>{getPairName(row.pairId)}</span>
                  <span className={`text-center ${i < 2 ? 'text-slate-300' : 'text-slate-500'}`}>{row.wins}</span>
                  <span className={`text-center ${i < 2 ? 'text-slate-300' : 'text-slate-500'}`}>{row.losses}</span>
                  <span className={`text-center font-medium ${row.pointDiff > 0 ? 'text-green-400' : row.pointDiff < 0 ? 'text-red-400' : 'text-slate-500'}`}>
                    {row.pointDiff > 0 ? `+${row.pointDiff}` : row.pointDiff === 0 ? '—' : row.pointDiff}
                  </span>
                  <span className={`w-1.5 h-1.5 rounded-full mx-auto ${i < 2 ? 'bg-yellow-400' : ''}`} />
                </div>
              ))}
            </div>
          </div>
        )
      })}

      {activeMatch && (
        <ScoreModal
          match={activeMatch}
          pairAName={getPairName(activeMatch.pairAId)}
          pairBName={getPairName(activeMatch.pairBId)}
          onConfirm={(a, b) => { onSetMatchScore(activeMatch.id, a, b); setActiveMatchId(null) }}
          onClose={() => setActiveMatchId(null)}
          isFetching={isFetching}
          refetch={refetch}
        />
      )}
    </div>
  )
}
