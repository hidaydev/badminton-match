// useScoreDraft — state draft skor inline (expand input, validasi, simpan).
import { useState } from 'react'
import { validateScore } from '../../utils/scoreValidation'

export interface ScoreDraftState {
  expandedScore: string | null
  setExpandedScore: (v: string | null) => void
  scoreError: string | null
  setScoreError: (v: string | null) => void
  draftScores: Record<string, { a: string; b: string }>
  setDraftScores: React.Dispatch<React.SetStateAction<Record<string, { a: string; b: string }>>>
  handleScoreSave: (key: string) => void
  reset: () => void
}

export function useScoreDraft(
  onSetGameScore?: (key: string, a: number, b: number) => void,
): ScoreDraftState {
  const [expandedScore, setExpandedScore] = useState<string | null>(null)
  const [scoreError, setScoreError] = useState<string | null>(null)
  const [draftScores, setDraftScores] = useState<Record<string, { a: string; b: string }>>({})

  function trySaveScore(key: string): boolean {
    const draft = draftScores[key]
    if (!draft) return false
    const a = parseInt(draft.a, 10)
    const b = parseInt(draft.b, 10)
    if (isNaN(a) || isNaN(b)) return false
    const err = validateScore(a, b)
    if (err) { setScoreError(err); return false }
    setScoreError(null)
    onSetGameScore?.(key, a, b)
    return true
  }

  function handleScoreSave(key: string) {
    if (trySaveScore(key)) setExpandedScore(null)
  }

  function reset() {
    setExpandedScore(null)
    setDraftScores({})
    setScoreError(null)
  }

  return { expandedScore, setExpandedScore, scoreError, setScoreError, draftScores, setDraftScores, handleScoreSave, reset }
}
