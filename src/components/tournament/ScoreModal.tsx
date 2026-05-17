import { useState, useEffect } from 'react'
import type { TournamentMatch } from '../../utils/tournament'
import ScoreboardOverlay from './ScoreboardOverlay'

interface Props {
  match: TournamentMatch
  pairAName: string
  pairBName: string
  onConfirm: (scoreA: number, scoreB: number) => void
  onClose: () => void
  isFetching?: boolean
  refetch: () => Promise<unknown>
}

export default function ScoreModal({ match, pairAName, pairBName, onConfirm, onClose, isFetching = false, refetch }: Props) {
  const [scoreA, setScoreA] = useState(match.scoreA?.toString() ?? '')
  const [scoreB, setScoreB] = useState(match.scoreB?.toString() ?? '')
  const [showScoreboard, setShowScoreboard] = useState(false)

  // Sync inputs with fresh match data once the refetch completes
  useEffect(() => {
    if (!isFetching) {
      setScoreA(match.scoreA?.toString() ?? '')
      setScoreB(match.scoreB?.toString() ?? '')
    }
  }, [isFetching, match.scoreA, match.scoreB])

  const a = parseInt(scoreA, 10)
  const b = parseInt(scoreB, 10)
  const valid = !isNaN(a) && !isNaN(b) && a >= 0 && b >= 0 && a !== b

  if (showScoreboard) {
    return (
      <ScoreboardOverlay
        matchId={match.id}
        pairAName={pairAName}
        pairBName={pairBName}
        onSave={async (sA, sB) => {
          await refetch()
          onConfirm(sA, sB)
          setShowScoreboard(false)
        }}
        onClose={() => setShowScoreboard(false)}
      />
    )
  }

  return (
    <div className="fixed inset-0 bg-black/70 z-50 flex items-end sm:items-center justify-center p-4" onClick={onClose}>
      <div className="bg-slate-800 rounded-2xl w-full max-w-sm p-5 relative" onClick={(e) => e.stopPropagation()}>
        {isFetching && (
          <div className="absolute inset-0 rounded-2xl z-10 flex items-center justify-center" style={{ background: 'rgba(15,23,42,0.55)' }}>
            <div className="flex items-center gap-2 px-4 py-2 rounded-full" style={{ background: 'rgba(30,41,59,0.95)', border: '1px solid rgba(148,163,184,0.15)' }}>
              <svg className="animate-spin w-3.5 h-3.5 text-yellow-400 shrink-0" viewBox="0 0 24 24" fill="none">
                <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
              </svg>
              <span className="text-xs text-slate-300 font-medium">Refreshing…</span>
            </div>
          </div>
        )}

        <h3 className="text-sm font-bold text-slate-300 text-center mb-1">Enter Score</h3>
        <p className="text-xs text-slate-500 text-center mb-4">
          {pairAName} vs {pairBName}
        </p>

        <div className="flex items-center gap-3 mb-5">
          <div className="flex-1 flex flex-col items-center gap-1">
            <span className="text-xs text-slate-400 font-medium truncate w-full text-center">{pairAName}</span>
            <input
              type="number"
              min={0}
              value={scoreA}
              onChange={(e) => setScoreA(e.target.value)}
              disabled={isFetching}
              className="w-full bg-slate-900 border border-slate-700 rounded-xl px-3 py-3 text-2xl font-bold text-yellow-400 text-center focus:outline-none focus:border-yellow-500 disabled:opacity-50"
              placeholder="0"
            />
          </div>
          <span className="text-slate-600 font-bold text-lg pt-5">vs</span>
          <div className="flex-1 flex flex-col items-center gap-1">
            <span className="text-xs text-slate-400 font-medium truncate w-full text-center">{pairBName}</span>
            <input
              type="number"
              min={0}
              value={scoreB}
              onChange={(e) => setScoreB(e.target.value)}
              disabled={isFetching}
              className="w-full bg-slate-900 border border-slate-700 rounded-xl px-3 py-3 text-2xl font-bold text-yellow-400 text-center focus:outline-none focus:border-yellow-500 disabled:opacity-50"
              placeholder="0"
            />
          </div>
        </div>

        {!isNaN(a) && !isNaN(b) && a === b && (
          <p className="text-xs text-red-400 text-center mb-3">Scores cannot be equal (no draws)</p>
        )}

        <div className="flex gap-3 mb-3">
          <button
            onClick={onClose}
            className="flex-1 py-3 rounded-xl bg-slate-700 text-slate-300 text-sm font-semibold"
          >
            Cancel
          </button>
          <button
            onClick={() => valid && onConfirm(a, b)}
            disabled={!valid || isFetching}
            className="flex-1 py-3 rounded-xl bg-yellow-400 text-slate-900 text-sm font-bold disabled:opacity-40 disabled:cursor-not-allowed"
          >
            Confirm
          </button>
        </div>

        <button
          onClick={() => setShowScoreboard(true)}
          disabled={isFetching}
          className="w-full py-2.5 rounded-xl text-slate-400 text-sm font-medium flex items-center justify-center gap-2 active:bg-slate-700/60 transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
          style={{ border: '1px solid rgba(148,163,184,0.15)' }}
        >
          🎯 Open Scoreboard
        </button>
      </div>
    </div>
  )
}
