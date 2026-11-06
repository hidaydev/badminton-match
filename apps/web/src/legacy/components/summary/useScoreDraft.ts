// useScoreDraft — state draft skor inline (expand input, validasi, simpan).
import { useState } from 'react'
import type { GameScore, SessionScoring, SetScore } from '../../types'
import { validateScore } from '../../utils/scoreValidation'
import { matchComplete, validateSet, validateSets } from '../../utils/scoring'

export type SetDraft = { a: string; b: string }
export type MatchDraft = SetDraft[]

const emptyRow = (): SetDraft => ({ a: '', b: '' })

/** The editor's starting rows for a stored score. */
export function draftFromScore(score?: GameScore, rules?: SessionScoring): MatchDraft {
  if (!score) return [emptyRow()]
  const rows: MatchDraft = score.sets && score.sets.length > 0
    ? score.sets.map((set) => ({ a: String(set.a), b: String(set.b) }))
    : [{ a: String(score.a), b: String(score.b) }]
  // A partial match stays editable without touching an existing row: the next
  // set gets an empty row of its own.
  const parsed = rows.map(parseRow).filter((set): set is SetScore => set !== null)
  if (rules && parsed.length === rows.length && !matchComplete(rules, parsed) &&
      rows.length < 2 * rules.gamesToWin - 1) {
    rows.push(emptyRow())
  }
  return rows
}

function parseRow(row: SetDraft): SetScore | null {
  if (row.a.trim() === '' || row.b.trim() === '') return null
  const a = Number.parseInt(row.a, 10)
  const b = Number.parseInt(row.b, 10)
  if (Number.isNaN(a) || Number.isNaN(b)) return null
  return { a, b }
}

export interface ScoreDraftState {
  expandedScore: string | null
  setExpandedScore: (v: string | null) => void
  scoreError: string | null
  setScoreError: (v: string | null) => void
  draftScores: Record<string, MatchDraft>
  setDraftScores: React.Dispatch<React.SetStateAction<Record<string, MatchDraft>>>
  updateDraftSet: (key: string, index: number, side: 'a' | 'b', value: string) => void
  handleScoreSave: (key: string) => void
  handleClearScore: (key: string) => void
  reset: () => void
}

export function useScoreDraft(
  onSetGameScore?: (key: string, sets: SetScore[]) => void,
  rules?: SessionScoring,
): ScoreDraftState {
  const [expandedScore, setExpandedScore] = useState<string | null>(null)
  const [scoreError, setScoreError] = useState<string | null>(null)
  const [draftScores, setDraftScores] = useState<Record<string, MatchDraft>>({})

  function updateDraftSet(key: string, index: number, side: 'a' | 'b', value: string): void {
    setDraftScores((prev) => {
      const rows = [...(prev[key] ?? [emptyRow()])]
      rows[index] = { ...(rows[index] ?? emptyRow()), [side]: value }
      // A row that is already a legal set opens the next one, unless the match
      // is decided or the format has no room left.
      if (rules && index === rows.length - 1) {
        const parsed = parseRow(rows[index])
        if (parsed && validateSet(rules, parsed, index + 1) === null) {
          const soFar = rows.map(parseRow).filter((set): set is SetScore => set !== null)
          const maxSets = 2 * rules.gamesToWin - 1
          if (!matchComplete(rules, soFar) && rows.length < maxSets) rows.push(emptyRow())
        }
      }
      return { ...prev, [key]: rows }
    })
  }

  function handleScoreSave(key: string): void {
    const rows = [...(draftScores[key] ?? [])]
    // A trailing empty row is the invitation to add a set, not an error.
    while (rows.length > 0 && rows[rows.length - 1].a.trim() === '' && rows[rows.length - 1].b.trim() === '') {
      rows.pop()
    }
    if (rows.length === 0) {
      setScoreError('Enter at least one set')
      return
    }
    const sets: SetScore[] = []
    for (let index = 0; index < rows.length; index += 1) {
      const parsed = parseRow(rows[index])
      if (parsed === null) {
        setScoreError(`Set ${index + 1} is empty`)
        return
      }
      const error = rules ? validateSet(rules, parsed, index + 1) : validateScore(parsed.a, parsed.b)
      if (error !== null) {
        setScoreError(error)
        return
      }
      sets.push(parsed)
    }
    if (rules) {
      const verdict = validateSets(rules, sets)
      if (verdict.error !== null) {
        setScoreError(verdict.error)
        return
      }
    }
    setScoreError(null)
    onSetGameScore?.(key, sets)
    setExpandedScore(null)
  }

  function handleClearScore(key: string): void {
    if (onSetGameScore === undefined) return
    setScoreError(null)
    onSetGameScore(key, [])
    setExpandedScore(null)
  }

  function reset() {
    setExpandedScore(null)
    setDraftScores({})
    setScoreError(null)
  }

  return {
    expandedScore,
    setExpandedScore,
    scoreError,
    setScoreError,
    draftScores,
    setDraftScores,
    updateDraftSet,
    handleScoreSave,
    handleClearScore,
    reset,
  }
}