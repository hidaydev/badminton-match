import { useState } from 'react'
import type { TournamentMatch } from '../../utils/tournament'
import { validateScore } from '../../utils/scoreValidation'
import ScoreboardOverlay from './ScoreboardOverlay'
import { useEscapeKey } from '../../hooks/useEscapeKey'

interface ScoreModalProps {
  match: TournamentMatch
  pairAName: string
  pairBName: string
  onConfirm: (scoreA: number, scoreB: number) => void
  onClose: () => void
  isFetching?: boolean
  refetch: () => Promise<unknown>
}

export default function ScoreModal({ match, pairAName, pairBName, onConfirm, onClose, isFetching = false, refetch }: ScoreModalProps) {
  const [scoreA, setScoreA] = useState(match.scoreA?.toString() ?? '')
  const [scoreB, setScoreB] = useState(match.scoreB?.toString() ?? '')
  const [showScoreboard, setShowScoreboard] = useState(false)

  useEscapeKey(onClose, !showScoreboard)

  const a = parseInt(scoreA, 10)
  const b = parseInt(scoreB, 10)
  const hasNumbers = !isNaN(a) && !isNaN(b)
  const validationError = hasNumbers ? validateScore(a, b) : null
  const valid = hasNumbers && validationError === null

  if (showScoreboard) {
    return (
      <ScoreboardOverlay
        matchId={match.id}
        pairAName={pairAName}
        pairBName={pairBName}
        initialScoreA={match.scoreA ?? 0}
        initialScoreB={match.scoreB ?? 0}
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
      <div className="fixed inset-0 bg-black/70 z-50 flex items-end sm:items-center justify-center p-4" onClick={onClose} role="dialog" aria-modal="true" aria-label="Enter score">
        <div className="bg-surface border border-border rounded-xl w-full max-w-sm p-5 shadow-lg" onClick={(e) => e.stopPropagation()}>
          <div className="animate-pulse">
            <div className="h-5 bg-elevated rounded w-1/3 mx-auto mb-1" />
            <div className="h-4 bg-elevated rounded w-1/2 mx-auto mb-4" />
            <div className="flex items-center gap-3 mb-5">
              <div className="flex-1 flex flex-col items-center gap-1">
                <div className="h-4 bg-elevated rounded w-3/4" />
                <div className="h-11.75 bg-elevated rounded-xl w-full" />
              </div>
              <div className="w-6 shrink-0" />
              <div className="flex-1 flex flex-col items-center gap-1">
                <div className="h-4 bg-elevated rounded w-3/4" />
                <div className="h-11.75 bg-elevated rounded-xl w-full" />
              </div>
            </div>
            <div className="flex gap-3 mb-3">
              <div className="flex-1 h-11 bg-elevated rounded-xl" />
              <div className="flex-1 h-11 bg-accent/20 rounded-xl" />
            </div>
            <div className="h-10 bg-elevated/60 rounded-xl" />
          </div>
        </div>
      </div>
    )
  }

  return (
    <div className="fixed inset-0 bg-black/70 z-50 flex items-end sm:items-center justify-center p-4" onClick={onClose}>
      <div className="bg-surface border border-border rounded-xl w-full max-w-sm p-5 shadow-lg" onClick={(e) => e.stopPropagation()}>
        <h3 className="text-sm font-bold text-fg text-center mb-1">Enter Score</h3>
        <p className="text-xs text-fg-dim text-center mb-4">
          {pairAName} vs {pairBName}
        </p>

        <div className="flex items-center gap-3 mb-5">
          <div className="flex-1 flex flex-col items-center gap-1">
            <span className="text-xs text-fg-dim font-medium truncate w-full text-center">{pairAName}</span>
            <input
              type="number"
              min={0}
              value={scoreA}
              onChange={(e) => setScoreA(e.target.value)}
              className="w-full bg-elevated border border-border rounded-xl px-3 py-3 text-2xl font-bold font-mono text-accent text-center focus:outline-none focus:border-accent focus-visible:ring-2 focus-visible:ring-accent/50"
              placeholder="0"
            />
          </div>
          <span className="text-fg-dim font-bold text-lg pt-5">vs</span>
          <div className="flex-1 flex flex-col items-center gap-1">
            <span className="text-xs text-fg-dim font-medium truncate w-full text-center">{pairBName}</span>
            <input
              type="number"
              min={0}
              value={scoreB}
              onChange={(e) => setScoreB(e.target.value)}
              className="w-full bg-elevated border border-border rounded-xl px-3 py-3 text-2xl font-bold font-mono text-accent text-center focus:outline-none focus:border-accent focus-visible:ring-2 focus-visible:ring-accent/50"
              placeholder="0"
            />
          </div>
        </div>

        {validationError && (
          <p className="text-xs text-error text-center mb-3">
            {a === b ? 'Scores cannot be equal (no draws)' : validationError}
          </p>
        )}

        <div className="flex gap-3 mb-3">
          <button
            onClick={onClose}
            className="flex-1 py-3 rounded-xl bg-elevated border border-border hover:bg-border text-fg text-sm font-semibold transition-colors"
          >
            Cancel
          </button>
          <button
            onClick={() => valid && onConfirm(a, b)}
            disabled={!valid}
            className="flex-1 py-3 rounded-xl bg-accent text-slate-950 text-sm font-bold disabled:opacity-40 disabled:cursor-not-allowed hover:bg-accent/90 active:scale-98 transition-all"
          >
            Confirm
          </button>
        </div>

        <button
          onClick={() => setShowScoreboard(true)}
          className="w-full py-2.5 rounded-xl text-fg-dim border border-border text-sm font-medium flex items-center justify-center gap-2 hover:bg-elevated hover:text-fg active:bg-elevated/60 transition-colors"
        >
          Open Scoreboard
        </button>
      </div>
    </div>
  )
}
