import { useState } from 'react'
import { useTournamentStore } from '../../store/tournament'
import type { TournamentMatch } from '../../store/tournament'
import ScoreModal from './ScoreModal'

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
  if (!match) return <div className="h-12 bg-slate-800/30 rounded-lg" />
  const canEnter = !!(match.pairAId && match.pairBId)
  return (
    <button
      onClick={() => canEnter && onSelect(match)}
      disabled={!canEnter}
      className={`w-full bg-slate-800 rounded-lg px-2 py-1.5 text-left border-l-2 ${borderColor} disabled:opacity-60 hover:bg-slate-700/50 disabled:hover:bg-slate-800`}
    >
      <div className={`text-[8px] font-bold tracking-wide mb-1 ${labelColor}`}>{label}</div>
      <div className="text-[10px] text-slate-300 truncate leading-tight">{getPairName(match.pairAId)}</div>
      {match.scoreA !== null ? (
        <div className="text-[9px] font-bold text-yellow-400 text-center my-0.5">
          {match.scoreA} – {match.scoreB}
        </div>
      ) : (
        <div className="text-[8px] text-slate-600 text-center my-0.5">vs</div>
      )}
      <div className="text-[10px] text-slate-300 truncate leading-tight">{getPairName(match.pairBId)}</div>
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

export default function BracketTab() {
  const pairs = useTournamentStore((s) => s.pairs)
  const matches = useTournamentStore((s) => s.matches)
  const setMatchScore = useTournamentStore((s) => s.setMatchScore)
  const [activeMatch, setActiveMatch] = useState<TournamentMatch | null>(null)

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
        <div className="min-w-[480px]">
          {/* Column headers */}
          <div className="grid grid-cols-[1fr_12px_90px_12px_80px] mb-2 text-[9px] text-slate-600 uppercase tracking-widest">
            <span className="text-center">Quarter Final</span>
            <span />
            <span className="text-center">Semi Final</span>
            <span />
            <span className="text-center">Final</span>
          </div>

          {/* Upper half: QF1+QF2 → SF1 → Final */}
          <div className="grid grid-cols-[1fr_12px_90px_12px_80px] items-center mb-1.5">
            <div className="flex flex-col gap-1.5">
              <MatchCard match={qf1} label="QF 1 · A1 vs B2" borderColor="border-yellow-500" labelColor="text-yellow-500" getPairName={getPairName} onSelect={setActiveMatch} />
              <MatchCard match={qf2} label="QF 2 · C2 vs D1" borderColor="border-yellow-500" labelColor="text-yellow-500" getPairName={getPairName} onSelect={setActiveMatch} />
            </div>
            <Connector />
            <MatchCard match={sf1} label="SEMI FINAL 1" borderColor="border-violet-500" labelColor="text-violet-400" getPairName={getPairName} onSelect={setActiveMatch} />
            <Connector />
            <MatchCard match={final} label="🏆 FINAL" borderColor="border-amber-500" labelColor="text-amber-400" getPairName={getPairName} onSelect={setActiveMatch} />
          </div>

          {/* Lower half: QF3+QF4 → SF2 | 3RD PLACE (no connector) */}
          <div className="grid grid-cols-[1fr_12px_90px_12px_80px] items-center">
            <div className="flex flex-col gap-1.5">
              <MatchCard match={qf3} label="QF 3 · C1 vs D2" borderColor="border-yellow-500" labelColor="text-yellow-500" getPairName={getPairName} onSelect={setActiveMatch} />
              <MatchCard match={qf4} label="QF 4 · A2 vs B1" borderColor="border-yellow-500" labelColor="text-yellow-500" getPairName={getPairName} onSelect={setActiveMatch} />
            </div>
            <Connector />
            <MatchCard match={sf2} label="SEMI FINAL 2" borderColor="border-violet-500" labelColor="text-violet-400" getPairName={getPairName} onSelect={setActiveMatch} />
            <span /> {/* no connector to 3rd place */}
            <MatchCard match={third} label="🥉 3RD PLACE" borderColor="border-slate-600" labelColor="text-slate-500" getPairName={getPairName} onSelect={setActiveMatch} />
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
          onConfirm={(a, b) => { setMatchScore(activeMatch.id, a, b); setActiveMatch(null) }}
          onClose={() => setActiveMatch(null)}
        />
      )}
    </div>
  )
}
