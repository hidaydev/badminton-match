import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { ApiError } from '../../auth/api'
import { t } from '../../i18n'
import type { MessageKey } from '../../i18n'
import { createTournament } from '../api'
import type { ClassicPhase, ClassicSnapshot, Pair } from '../types'
import { GROUP_IDS, generateTournament } from './draw'
import { MatchList } from './MatchScoreRow'
import { StandingsTable } from './StandingsTable'
import { phaseLabel } from './labels'

const PAIR_IDS = Array.from({ length: 16 }, (_, index) => `p${index + 1}`)

const BRACKET_PHASES: readonly ClassicPhase[] = ['qf', 'sf', '3rd', 'final']

function today(): string {
  return new Date().toISOString().slice(0, 10)
}

type Props = { slug: string }

/**
 * Wizard for a new classic tournament: 16 pair names, a draft name/date, then a
 * seeded draw rendered in the browser.
 *
 * The seed lives in component state on purpose. v1 reshuffled with
 * `Math.random()`, so a redraw could never be reproduced; here the whole draw
 * is a pure function of the pair ids and the seed, and a redraw advances the
 * seeded sequence instead of calling an unseeded random source.
 */
export function ClassicNewPage({ slug }: Props) {
  const navigate = useNavigate()
  const [name, setName] = useState('')
  const [date, setDate] = useState(today)
  const [pairNames, setPairNames] = useState<string[]>(() =>
    Array.from({ length: 16 }, () => ''),
  )
  const [seed, setSeed] = useState(() => Date.now() % 0x7fffffff)
  const [draft, setDraft] = useState<ClassicSnapshot | null>(null)
  const [error, setError] = useState<MessageKey | null>(null)
  const [creating, setCreating] = useState(false)

  const pairs = (): Pair[] =>
    pairNames.map((pairName, index) => ({
      id: PAIR_IDS[index],
      name: pairName.trim(),
    }))

  const draw = () => {
    const nextPairs = pairs()
    if (nextPairs.some((pair) => pair.name === '')) {
      setError('tournament.error.invalid')
      return
    }
    const nextSeed =
      draft === null ? seed : (Math.imul(seed, 1664525) + 1013904223) >>> 0
    setSeed(nextSeed)
    setDraft(generateTournament(name.trim(), date, nextPairs, nextSeed))
    setError(null)
  }

  const create = async () => {
    if (draft === null) return
    if (name.trim() === '' || date === '') {
      setError('tournament.error.invalid')
      return
    }
    setCreating(true)
    setError(null)
    try {
      const created = await createTournament(slug, { ...draft, name: name.trim(), date })
      if (created.id === undefined) {
        setError('tournament.error.invalid')
        return
      }
      navigate(
        `/c/${encodeURIComponent(slug)}/tournaments/classic/${encodeURIComponent(created.id)}`,
      )
    } catch (failure: unknown) {
      setError(
        failure instanceof ApiError && failure.status === 412
          ? 'tournament.error.conflict'
          : 'tournament.error.invalid',
      )
    } finally {
      setCreating(false)
    }
  }

  const names = new Map((draft?.pairs ?? []).map((pair) => [pair.id, pair.name]))
  const nameOf = (pairId: string | null) =>
    pairId === null ? t('classic.tbd') : (names.get(pairId) ?? pairId)

  const groupMatches = (groupId: (typeof GROUP_IDS)[number]) =>
    draft === null
      ? []
      : draft.matches.filter(
          (match) => match.phase === 'group' && match.groupId === groupId,
        )

  const knockout = draft?.matches ?? []

  return (
    <section className="mx-auto max-w-4xl p-4">
      <Link
        to={`/c/${encodeURIComponent(slug)}/tournaments`}
        className="inline-flex min-h-11 items-center rounded-xl px-2 text-sm text-fg-dim hover:bg-elevated hover:text-fg focus-visible:ring-2 focus-visible:ring-accent"
      >
        {t('tournaments.title')}
      </Link>

      <h1 className="mt-2 text-xl font-bold text-fg sm:text-2xl">
        {t('tournaments.newClassic')}
      </h1>

      <form
        className="mt-4 grid gap-3 sm:grid-cols-2"
        onSubmit={(event) => {
          event.preventDefault()
          draw()
        }}
      >
        <div className="grid gap-1">
          <label htmlFor="classic-name" className="text-xs text-fg-dim">
            {t('tournament.name')}
          </label>
          <input
            id="classic-name"
            value={name}
            onChange={(event) => setName(event.target.value)}
            className="min-h-11 rounded-xl border border-border bg-elevated px-3 py-1.5 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
          />
        </div>
        <div className="grid gap-1">
          <label htmlFor="classic-date" className="text-xs text-fg-dim">
            {t('tournament.date')}
          </label>
          <input
            id="classic-date"
            type="date"
            value={date}
            onChange={(event) => setDate(event.target.value)}
            className="min-h-11 rounded-xl border border-border bg-elevated px-3 py-1.5 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
          />
        </div>
      </form>

      <h2 className="mt-6 text-sm font-semibold text-fg">{t('classic.pairs')}</h2>
      <div className="mt-2 grid gap-2 sm:grid-cols-2">
        {pairNames.map((pairName, index) => {
          const inputId = `classic-pair-${index + 1}`
          return (
            <div key={inputId} className="grid gap-1">
              <label htmlFor={inputId} className="text-xs text-fg-dim">
                {`${t('classic.pair')} ${index + 1}`}
              </label>
              <input
                id={inputId}
                value={pairName}
                onChange={(event) => {
                  const next = [...pairNames]
                  next[index] = event.target.value
                  setPairNames(next)
                  setDraft(null)
                }}
                className="min-h-11 rounded-xl border border-border bg-elevated px-3 py-1.5 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
              />
            </div>
          )
        })}
      </div>

      <div className="mt-4 flex flex-wrap items-center gap-3">
        <button
          type="button"
          onClick={draw}
          className="min-h-11 rounded-xl border border-border bg-elevated px-4 text-sm text-fg hover:bg-surface focus-visible:ring-2 focus-visible:ring-accent"
        >
          {t('classic.draw')}
        </button>
        {draft !== null && (
          <button
            type="button"
            onClick={() => void create()}
            disabled={creating}
            className="min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40"
          >
            {creating ? t('tournament.creating') : t('tournament.save')}
          </button>
        )}
      </div>

      {draft !== null && (
        <p className="mt-2 text-xs text-fg-dim">{t('classic.drawHint')}</p>
      )}
      {error !== null && (
        <p role="alert" className="mt-3 text-sm text-error">
          {t(error)}
        </p>
      )}

      {draft !== null && (
        <>
          <h2 className="mt-8 text-sm font-semibold text-fg">{t('classic.groups')}</h2>
          <div className="mt-2 grid gap-4 lg:grid-cols-2">
            {GROUP_IDS.map((groupId) => (
              <div
                key={groupId}
                className="rounded-2xl border border-border-subtle bg-ground p-3"
              >
                <h3 className="text-sm font-semibold text-fg">
                  {t('classic.group', { group: groupId })}
                </h3>
                <StandingsTable
                  groupId={groupId}
                  pairIds={draft.groups[groupId] ?? []}
                  matches={draft.matches}
                  nameOf={nameOf}
                />
                <MatchList matches={groupMatches(groupId)} nameOf={nameOf} />
              </div>
            ))}
          </div>

          <h2 className="mt-8 text-sm font-semibold text-fg">{t('classic.bracket')}</h2>
          {BRACKET_PHASES.map((phase) => {
            const matches = knockout.filter((match) => match.phase === phase)
            return (
              <div key={phase} className="mt-4">
                <h3 className="text-sm font-semibold text-fg">{phaseLabel(phase)}</h3>
                <MatchList matches={matches} nameOf={nameOf} />
              </div>
            )
          })}
        </>
      )}
    </section>
  )
}
