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

  if (isFetching) {
    return (
      <div className="fixed inset-0 bg-black/70 z-50 flex items-end sm:items-center justify-center p-4" onClick={onClose}>
        <div className="bg-slate-800 rounded-2xl w-full max-w-sm p-5" onClick={(e) => e.stopPropagation()}>
          <div className="animate-pulse">
            <div className="h-5 bg-slate-700 rounded w-1/3 mx-auto mb-1" />
            <div className="h-4 bg-slate-700 rounded w-1/2 mx-auto mb-4" />
            <div className="flex items-center gap-3 mb-5">
              <div className="flex-1 flex flex-col items-center gap-1">
                <div className="h-4 bg-slate-700 rounded w-3/4" />
                <div className="h-[47px] bg-slate-700 rounded-xl w-full" />
              </div>
              <div className="w-6 shrink-0" />
              <div className="flex-1 flex flex-col items-center gap-1">
                <div className="h-4 bg-slate-700 rounded w-3/4" />
                <div className="h-[47px] bg-slate-700 rounded-xl w-full" />
              </div>
            </div>
            <div className="flex gap-3">
              <div className="flex-1 h-11 bg-slate-700 rounded-xl" />
              <div className="flex-1 h-11 bg-yellow-400/20 rounded-xl" />
            </div>
          </div>
        </div>
      </div>
    )
  }

  return (
    <div className="fixed inset-0 bg-black/70 z-50 flex items-end sm:items-center justify-center p-4" onClick={onClose}>
      <div className="bg-slate-800 rounded-2xl w-full max-w-sm p-5" onClick={(e) => e.stopPropagation()}>
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
              className="w-full bg-slate-900 border border-slate-700 rounded-xl px-3 py-3 text-2xl font-bold text-yellow-400 text-center focus:outline-none focus:border-yellow-500"
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
              className="w-full bg-slate-900 border border-slate-700 rounded-xl px-3 py-3 text-2xl font-bold text-yellow-400 text-center focus:outline-none focus:border-yellow-500"
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
            disabled={!valid}
            className="flex-1 py-3 rounded-xl bg-yellow-400 text-slate-900 text-sm font-bold disabled:opacity-40 disabled:cursor-not-allowed"
          >
            Confirm
          </button>
        </div>

        <button
          onClick={() => setShowScoreboard(true)}
          className="w-full py-2.5 rounded-xl text-slate-400 text-sm font-medium flex items-center justify-center gap-2 active:bg-slate-700/60 transition-colors"
          style={{ border: '1px solid rgba(148,163,184,0.15)' }}
        >
          🎯 Open Scoreboard
        </button>
      </div>
    </div>
  )
}
