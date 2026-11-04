import { useState } from 'react'
import { t } from '../../i18n'
import type { MessageKey } from '../../i18n/en'
import type { TeamMatch, TeamPartai } from '../types'
import { partaiClasses, targetScore } from './rules'
import type { TeamMatchPatch } from './rules'

type ScoreDraft = { a: string; b: string }

type Props = {
  match: TeamMatch
  teamName: (teamId: string) => string
  /** Resolves to null on success, or the message key to show on failure. */
  onSave: (matchId: string, patch: TeamMatchPatch) => Promise<MessageKey | null>
}

function initialScores(partai: readonly TeamPartai[]): ScoreDraft[] {
  return [0, 1, 2].map((index) => {
    const entry = partai[index]
    return {
      a: entry !== undefined && entry.scoreA !== null ? String(entry.scoreA) : '',
      b: entry !== undefined && entry.scoreB !== null ? String(entry.scoreB) : '',
    }
  })
}

/** null = unplayed, undefined = not a 0..99 integer (mirrors the server cap). */
function parseScore(value: string): number | null | undefined {
  const trimmed = value.trim()
  if (trimmed === '') return null
  if (!/^\d+$/.test(trimmed)) return undefined
  const parsed = Number(trimmed)
  return parsed >= 0 && parsed <= 99 ? parsed : undefined
}

const inputClass =
  'mt-1 block w-full min-h-11 rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent'

/** One team-match: three partai scores plus the three court slots. */
export default function TeamMatchCard({ match, teamName, onSave }: Props) {
  const [courts, setCourts] = useState<[string, string, string]>([
    match.courts[0],
    match.courts[1],
    match.courts[2],
  ])
  const [scores, setScores] = useState<ScoreDraft[]>(() => initialScores(match.partai))
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<MessageKey | null>(null)

  const nextCourts: [string, string, string] = [
    courts[0].trim(),
    courts[1].trim(),
    courts[2].trim(),
  ]
  const nextPartai: TeamPartai[] = scores.map((score) => {
    const a = parseScore(score.a)
    const b = parseScore(score.b)
    return {
      scoreA: typeof a === 'number' ? a : null,
      scoreB: typeof b === 'number' ? b : null,
    }
  })

  const courtsChanged = nextCourts.some((court, index) => court !== match.courts[index])
  const partaiChanged = nextPartai.some((partai, index) => {
    const current = match.partai[index]
    return (
      (current?.scoreA ?? null) !== partai.scoreA ||
      (current?.scoreB ?? null) !== partai.scoreB
    )
  })
  const dirty = courtsChanged || partaiChanged

  const setScore = (index: number, side: 'a' | 'b', value: string) => {
    setScores((previous) =>
      previous.map((score, current) =>
        current === index ? { ...score, [side]: value } : score,
      ),
    )
  }

  const setCourt = (index: 0 | 1 | 2, value: string) => {
    setCourts((previous) => {
      const next: [string, string, string] = [previous[0], previous[1], previous[2]]
      next[index] = value
      return next
    })
  }

  const save = async () => {
    if (!dirty) return

    let invalid = nextCourts.some((court) => court === '')
    for (const score of scores) {
      const a = parseScore(score.a)
      const b = parseScore(score.b)
      if (a === undefined || b === undefined) invalid = true
      else if ((a === null) !== (b === null)) invalid = true
      else if (a !== null && b !== null && a === b) invalid = true
    }
    if (invalid) {
      setError('team.error.invalid')
      return
    }

    const patch: TeamMatchPatch = {}
    if (courtsChanged) patch.courts = nextCourts
    if (partaiChanged) patch.partai = nextPartai

    setError(null)
    setSaving(true)
    const failure = await onSave(match.id, patch)
    setSaving(false)
    if (failure !== null) setError(failure)
  }

  return (
    <article
      aria-labelledby={`${match.id}-title`}
      className="rounded-2xl border border-border-subtle bg-surface p-4"
    >
      <h3 id={`${match.id}-title`} className="text-sm font-semibold text-fg">
        {`${teamName(match.teamA)} — ${teamName(match.teamB)}`}
      </h3>
      <p className="mt-1 text-xs font-mono text-fg-dim">
        {t('team.target', { score: targetScore(match.phase) })}
      </p>

      <fieldset className="mt-3">
        <legend className="text-xs text-fg-dim">{t('team.courts')}</legend>
        <div className="mt-1 grid gap-2 sm:grid-cols-3">
          {courts.map((court, index) => (
            <div key={index}>
              <label htmlFor={`${match.id}-court-${index}`} className="text-xs text-fg-dim">
                {t('team.court')} {index + 1}
              </label>
              <input
                id={`${match.id}-court-${index}`}
                value={court}
                autoComplete="off"
                onChange={(event) =>
                  setCourt(index as 0 | 1 | 2, event.target.value)
                }
                className={inputClass}
              />
            </div>
          ))}
        </div>
      </fieldset>

      <fieldset className="mt-3">
        <legend className="text-xs text-fg-dim">{t('team.match')}</legend>
        <div className="mt-1 space-y-2">
          {scores.map((score, index) => {
            const classes = partaiClasses(index)
            return (
              <div
                key={index}
                className="rounded-xl border border-border-subtle bg-elevated p-2"
              >
                <p className="text-xs font-mono text-fg-dim">
                  {t('team.partai', { index: index + 1 })}
                  {classes !== null && ` · ${classes[0]} / ${classes[1]}`}
                </p>
                <div className="mt-1 grid grid-cols-2 gap-2">
                  <div>
                    <label
                      htmlFor={`${match.id}-partai-${index}-a`}
                      className="sr-only"
                    >
                      {t('team.partai', { index: index + 1 })} {teamName(match.teamA)}
                    </label>
                    <input
                      id={`${match.id}-partai-${index}-a`}
                      inputMode="numeric"
                      autoComplete="off"
                      value={score.a}
                      onChange={(event) => setScore(index, 'a', event.target.value)}
                      className={inputClass}
                    />
                  </div>
                  <div>
                    <label
                      htmlFor={`${match.id}-partai-${index}-b`}
                      className="sr-only"
                    >
                      {t('team.partai', { index: index + 1 })} {teamName(match.teamB)}
                    </label>
                    <input
                      id={`${match.id}-partai-${index}-b`}
                      inputMode="numeric"
                      autoComplete="off"
                      value={score.b}
                      onChange={(event) => setScore(index, 'b', event.target.value)}
                      className={inputClass}
                    />
                  </div>
                </div>
              </div>
            )
          })}
        </div>
      </fieldset>

      <button
        type="button"
        onClick={() => void save()}
        disabled={!dirty || saving}
        className="mt-3 min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground disabled:opacity-40 focus-visible:ring-2 focus-visible:ring-accent"
      >
        {saving ? t('tournament.saving') : t('tournament.save')}
      </button>

      {error !== null && (
        <p role="alert" aria-live="polite" className="mt-2 text-sm text-error">
          {t(error)}
        </p>
      )}
    </article>
  )
}
