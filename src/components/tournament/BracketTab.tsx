import { useState } from 'react'
import type { TournamentMatch, TournamentPair } from '../../utils/tournament'
import ScoreModal from './ScoreModal'

interface Props {
  pairs: TournamentPair[]
  matches: TournamentMatch[]
  onSetMatchScore: (matchId: string, scoreA: number, scoreB: number) => void
  onOpenModal: () => void
  isFetching: boolean
}

function MatchCard({
  match,
  label,
  borderColor,
  labelColor,
  getPairName,
  onSelect,
}: {
  match?: TournamentMatch
  label: string
  borderColor: string
  labelColor: string
  getPairName: (id: string | null) => string
  onSelect: (match: TournamentMatch) => void
}) {
  if (!match) return <div className="h-16 bg-slate-800/30 rounded-lg" />
  const canEnter = !!(match.pairAId && match.pairBId)
  const scored = match.scoreA !== null
  return (
    <button
      onClick={() => canEnter && onSelect(match)}
      disabled={!canEnter}
      className={`w-full bg-slate-800 rounded-lg text-left border-l-2 ${borderColor} overflow-hidden disabled:opacity-60 hover:bg-slate-700/50 disabled:hover:bg-slate-800`}
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
  )
}

function Connector() {
  return (
    <div className="flex items-stretch w-3 shrink-0">
      <div className="flex-1 border-t border-r border-b border-slate-700 rounded-r my-2" />
    </div>
  )
}

export default function BracketTab({ pairs, matches, onSetMatchScore, onOpenModal, isFetching }: Props) {
  const [activeMatchId, setActiveMatchId] = useState<string | null>(null)
  const activeMatch = activeMatchId ? (matches.find((m) => m.id === activeMatchId) ?? null) : null

  const handleSelect = (match: TournamentMatch) => {
    onOpenModal()
    setActiveMatchId(match.id)
  }

  const getPairName = (id: string | null) =>
    id ? (pairs.find((p) => p.id === id)?.name ?? id) : 'TBD'
  const get = (id: string) => matches.find((m) => m.id === id)

  const qf1 = get('qf-1'); const qf2 = get('qf-2')
  const qf3 = get('qf-3'); const qf4 = get('qf-4')
  const sf1 = get('sf-1'); const sf2 = get('sf-2')
  const final = get('final-1'); const third = get('3rd-1')

  if (!qf1) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-16 text-center">
        <span className="text-4xl">🏆</span>
        <p className="text-slate-400 text-sm">Assign groups and confirm to see the bracket.</p>
      </div>
    )
  }

  const winner = (m?: TournamentMatch) =>
    m?.scoreA !== null && m?.scoreA !== undefined
      ? getPairName(m.scoreA > m.scoreB! ? m.pairAId : m.pairBId)
      : null
  const loser = (m?: TournamentMatch) =>
    m?.scoreA !== null && m?.scoreA !== undefined
      ? getPairName(m.scoreA < m.scoreB! ? m.pairAId : m.pairBId)
      : null

  return (
    <div>
      {/* Bracket — horizontally scrollable */}
      <div className="overflow-x-auto -mx-3 px-3 pb-2">
        <div className="min-w-[300px] w-full">
          {/* Column headers */}
          <div className="grid grid-cols-[1fr_10px_1fr_10px_1fr] mb-2 text-[10px] text-slate-400 uppercase tracking-widest font-semibold">
            <span className="text-center">QF</span>
            <span />
            <span className="text-center">SF</span>
            <span />
            <span className="text-center">Final</span>
          </div>

          {/* Upper half: QF1+QF2 → SF1 → Final */}
          <div className="grid grid-cols-[1fr_10px_1fr_10px_1fr] items-center mb-3">
            <div className="flex flex-col gap-3">
              <MatchCard match={qf1} label="QF 1 · A1 vs B2" borderColor="border-sky-500" labelColor="text-sky-400" getPairName={getPairName} onSelect={handleSelect} />
              <MatchCard match={qf2} label="QF 2 · C2 vs D1" borderColor="border-sky-500" labelColor="text-sky-400" getPairName={getPairName} onSelect={handleSelect} />
            </div>
            <Connector />
            <MatchCard match={sf1} label="SEMI 1" borderColor="border-violet-500" labelColor="text-violet-400" getPairName={getPairName} onSelect={handleSelect} />
            <Connector />
            <MatchCard match={final} label="🏆 FINAL" borderColor="border-yellow-500" labelColor="text-yellow-400" getPairName={getPairName} onSelect={handleSelect} />
          </div>

          {/* Lower half: QF3+QF4 → SF2 | 3RD PLACE (no connector) */}
          <div className="grid grid-cols-[1fr_10px_1fr_10px_1fr] items-center">
            <div className="flex flex-col gap-3">
              <MatchCard match={qf3} label="QF 3 · C1 vs D2" borderColor="border-sky-500" labelColor="text-sky-400" getPairName={getPairName} onSelect={handleSelect} />
              <MatchCard match={qf4} label="QF 4 · A2 vs B1" borderColor="border-sky-500" labelColor="text-sky-400" getPairName={getPairName} onSelect={handleSelect} />
            </div>
            <Connector />
            <MatchCard match={sf2} label="SEMI 2" borderColor="border-violet-500" labelColor="text-violet-400" getPairName={getPairName} onSelect={handleSelect} />
            <span /> {/* no connector to 3rd place */}
            <MatchCard match={third} label="🥉 3RD" borderColor="border-slate-600" labelColor="text-slate-500" getPairName={getPairName} onSelect={handleSelect} />
          </div>
        </div>
      </div>

      {/* Podium — full width, outside horizontal scroll */}
      <div className="mt-5 bg-slate-800 rounded-2xl p-4 flex justify-around items-end">
        <div className="text-center">
          <div className="text-2xl">🥈</div>
          <div className="text-[10px] text-slate-500 mt-1">2nd</div>
          <div className="text-xs text-slate-300 mt-1 font-medium">{loser(final) ?? 'TBD'}</div>
        </div>
        <div className="text-center -mt-4">
          <div className="text-3xl">🏆</div>
          <div className="text-xs text-yellow-400 font-bold mt-1">CHAMPION</div>
          <div className="text-sm text-yellow-200 mt-1 font-bold">{winner(final) ?? 'TBD'}</div>
        </div>
        <div className="text-center">
          <div className="text-2xl">🥉</div>
          <div className="text-[10px] text-slate-500 mt-1">3rd</div>
          <div className="text-xs text-slate-300 mt-1 font-medium">{winner(third) ?? 'TBD'}</div>
        </div>
      </div>

      {activeMatch && (
        <ScoreModal
          match={activeMatch}
          pairAName={getPairName(activeMatch.pairAId)}
          pairBName={getPairName(activeMatch.pairBId)}
          onConfirm={(a, b) => { onSetMatchScore(activeMatch.id, a, b); setActiveMatchId(null) }}
          onClose={() => setActiveMatchId(null)}
          isFetching={isFetching}
        />
      )}
    </div>
  )
}
