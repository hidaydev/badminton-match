import { useState } from 'react'
import { t } from '../../i18n'
import type { MessageKey } from '../../i18n'
import type { ClassicMatch } from '../types'
import { MAX_SCORE, matchWinner } from './draw'
import { saveErrorKey } from './errors'
import { matchLabel } from './labels'

export type MatchScores = { scoreA: number | null; scoreB: number | null }

type Props = {
  match: ClassicMatch
  nameOf: (pairId: string | null) => string
  /** Omitting the handler renders the row read-only (draw preview). */
  onSave?: (scores: MatchScores) => Promise<void>
}

type Parsed = { scoreA: number | null; scoreB: number | null } | 'invalid' | 'tie'

/**
 * Both sides are required together, capped at 99 and never tied — the same
 * guard the domain validator applies. An empty pair of fields clears the result.
 */
function parseScores(rawA: string, rawB: string): Parsed {
  const valueA = rawA.trim()
  const valueB = rawB.trim()
  if (valueA === '' && valueB === '') return { scoreA: null, scoreB: null }
  if (valueA === '' || valueB === '') return 'invalid'
  if (!/^\d{1,2}$/.test(valueA) || !/^\d{1,2}$/.test(valueB)) return 'invalid'
  const scoreA = Number(valueA)
  const scoreB = Number(valueB)
  if (scoreA > MAX_SCORE || scoreB > MAX_SCORE) return 'invalid'
  if (scoreA === scoreB) return 'tie'
  return { scoreA, scoreB }
}

export function MatchScoreRow({ match, nameOf, onSave }: Props) {
  const label = matchLabel(match)
  const [rawA, setRawA] = useState(match.scoreA === null ? '' : String(match.scoreA))
  const [rawB, setRawB] = useState(match.scoreB === null ? '' : String(match.scoreB))
  const [error, setError] = useState<MessageKey | null>(null)
  const [saved, setSaved] = useState(false)
  const [saving, setSaving] = useState(false)

  const nameA = nameOf(match.pairAId)
  const nameB = nameOf(match.pairBId)
  const ready = match.pairAId !== null && match.pairBId !== null
  const winner = matchWinner(match)
  const editable = onSave !== undefined && ready

  const labelA = `${label} · ${t('classic.score')} ${nameA}`
  const labelB = `${label} · ${t('classic.score')} ${nameB}`
  const inputA = `${match.id}-score-a`
  const inputB = `${match.id}-score-b`

  const submit = async () => {
    if (onSave === undefined) return
    const parsed = parseScores(rawA, rawB)
    if (parsed === 'invalid' || parsed === 'tie') {
      setSaved(false)
      setError('tournament.error.invalid')
      return
    }
    setSaving(true)
    setError(null)
    try {
      await onSave(parsed)
      setSaved(true)
    } catch (failure: unknown) {
      setSaved(false)
      setError(saveErrorKey(failure))
    } finally {
      setSaving(false)
    }
  }

  return (
    <div
      role="group"
      aria-label={label}
      className="rounded-xl border border-border-subtle bg-surface p-3"
    >
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <p className="text-xs text-fg-dim">{label}</p>
        <p className="text-xs text-fg-dim">
          {winner === null ? t('classic.notPlayed') : t('classic.played')}
        </p>
      </div>

      <div className="mt-2 flex flex-wrap items-center gap-2">
        <span className="min-w-0 flex-1 truncate text-sm text-fg" title={nameA}>
          {nameA}
        </span>

        {!editable ? (
          <span className="font-mono text-sm text-fg-dim">
            {match.scoreA === null || match.scoreB === null
              ? t('classic.tbd')
              : `${match.scoreA}–${match.scoreB}`}
          </span>
        ) : (
          <>
            <label htmlFor={inputA} className="sr-only">
              {labelA}
            </label>
            <input
              id={inputA}
              type="number"
              inputMode="numeric"
              min={0}
              max={MAX_SCORE}
              step={1}
              value={rawA}
              disabled={!editable || saving}
              onChange={(event) => {
                setRawA(event.target.value)
                setSaved(false)
                setError(null)
              }}
              className="min-h-11 w-16 rounded-xl border border-border bg-elevated px-2 py-1 text-center font-mono text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40"
            />
            <span aria-hidden="true" className="text-fg-dim">
              –
            </span>
            <label htmlFor={inputB} className="sr-only">
              {labelB}
            </label>
            <input
              id={inputB}
              type="number"
              inputMode="numeric"
              min={0}
              max={MAX_SCORE}
              step={1}
              value={rawB}
              disabled={!editable || saving}
              onChange={(event) => {
                setRawB(event.target.value)
                setSaved(false)
                setError(null)
              }}
              className="min-h-11 w-16 rounded-xl border border-border bg-elevated px-2 py-1 text-center font-mono text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40"
            />
          </>
        )}

        <span className="min-w-0 flex-1 truncate text-sm text-fg" title={nameB}>
          {nameB}
        </span>

        {editable && (
          <button
            type="button"
            onClick={() => void submit()}
            disabled={saving}
            className="min-h-11 rounded-xl border border-border bg-elevated px-3 text-sm text-fg hover:bg-surface focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40"
          >
            {saving ? t('tournament.saving') : t('tournament.save')}
          </button>
        )}
      </div>

      {winner !== null && (
        <p className="mt-2 text-xs text-fg-dim">
          {t('classic.winner')}: {nameOf(winner)}
        </p>
      )}

      {error !== null && (
        <p role="alert" className="mt-2 text-xs text-error">
          {t(error)}
        </p>
      )}
      {saved && (
        <p role="status" className="mt-2 text-xs text-fg-dim">
          {t('tournament.saved')}
        </p>
      )}
    </div>
  )
}

/** One phase (or one group) of match rows. */
export function MatchList({
  matches,
  nameOf,
  onSave,
}: {
  matches: readonly ClassicMatch[]
  nameOf: (pairId: string | null) => string
  onSave?: (match: ClassicMatch, scores: MatchScores) => Promise<void>
}) {
  return (
    <div className="mt-3 grid gap-2">
      {matches.map((match) => (
        <MatchScoreRow
          // Remount only when the pairing changes (propagation cleared a score
          // and moved a pair); a score-only update must keep the row's inputs
          // and its "saved" status in place.
          key={`${match.id}:${match.pairAId ?? ''}:${match.pairBId ?? ''}`}
          match={match}
          nameOf={nameOf}
          onSave={
            onSave === undefined ? undefined : (scores) => onSave(match, scores)
          }
        />
      ))}
    </div>
  )
}
