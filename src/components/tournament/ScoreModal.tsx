import { useState } from 'react'
import type { TournamentMatch } from '../../store/tournament'

interface Props {
  match: TournamentMatch
  pairAName: string
  pairBName: string
  onConfirm: (scoreA: number, scoreB: number) => void
  onClose: () => void
}

export default function ScoreModal({ match, pairAName, pairBName, onConfirm, onClose }: Props) {
  const [scoreA, setScoreA] = useState(match.scoreA?.toString() ?? '')
  const [scoreB, setScoreB] = useState(match.scoreB?.toString() ?? '')

  const a = parseInt(scoreA, 10)
  const b = parseInt(scoreB, 10)
  const valid = !isNaN(a) && !isNaN(b) && a >= 0 && b >= 0 && a !== b

  return (
    <div className="fixed inset-0 bg-black/70 z-50 flex items-end sm:items-center justify-center p-4">
      <div className="bg-slate-800 rounded-2xl w-full max-w-sm p-5">
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

        <div className="flex gap-3">
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
      </div>
    </div>
  )
}
