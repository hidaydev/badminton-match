import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useCommunity } from '../../community/CommunityContext'
import { t } from '../../i18n'
import type { MessageKey } from '../../i18n'
import {
  getTournament,
  patchClassicMatch,
  replaceTournament,
} from '../api'
import { isTeam } from '../types'
import type {
  ClassicMatch,
  ClassicPhase,
  ClassicSnapshot,
  Tournament,
} from '../types'
import {
  GROUP_IDS,
  propagateBracket,
  sameMatches,
} from './draw'
import { loadErrorKey } from './errors'
import { MatchList } from './MatchScoreRow'
import type { MatchScores } from './MatchScoreRow'
import { StandingsTable } from './StandingsTable'
import { MetadataForm } from './MetadataForm'
import { AdminTools } from './AdminTools'
import { phaseLabel } from './labels'

const BRACKET_PHASES: readonly ClassicPhase[] = ['qf', 'sf', '3rd', 'final']

type Settled = {
  /** Slug + id the settled response belongs to; a stale reply is never shown. */
  key: string | null
  snapshot: ClassicSnapshot | null
  error: MessageKey | null
}

const UNRESOLVED: Settled = { key: null, snapshot: null, error: null }

function asClassic(body: Tournament): ClassicSnapshot {
  if (isTeam(body)) throw new Error('expected a classic tournament snapshot')
  return body
}

type Props = { slug: string; id: string }

/** Existing classic tournament: label standings, fixtures and bracket scores. */
export function ClassicEditorPage({ slug, id }: Props) {
  const navigate = useNavigate()
  const { memberships } = useCommunity()
  const isAdmin =
    memberships.find((candidate) => candidate.slug === slug)?.role === 'admin'

  const key = `${slug}\u0000${id}`
  const [settled, setSettled] = useState<Settled>(UNRESOLVED)

  useEffect(() => {
    let active = true
    getTournament(slug, id)
      .then((body) => {
        if (!active) return
        if (isTeam(body)) {
          setSettled({ key, snapshot: null, error: 'tournament.error.load' })
          return
        }
        setSettled({ key, snapshot: body, error: null })
      })
      .catch((failure: unknown) => {
        if (!active) return
        setSettled({ key, snapshot: null, error: loadErrorKey(failure) })
      })
    return () => {
      active = false
    }
  }, [slug, id, key])

  const current = settled.key === key
  const snapshot = current ? settled.snapshot : null
  const loadError = current ? settled.error : null
  const loading = !current

  const saveScore = async (match: ClassicMatch, scores: MatchScores) => {
    if (snapshot === null || snapshot.version === undefined) {
      throw new Error('the snapshot has no version')
    }
    const patched = asClassic(
      await patchClassicMatch(slug, id, match.id, scores, snapshot.version),
    )
    const propagated: ClassicSnapshot = {
      ...patched,
      matches: propagateBracket(patched.matches, patched.groups),
    }
    // A score changes the standings, so the QF seeding — and every slot
    // downstream — can move. Persist that propagation so a later score lands on
    // the same pairing the page is showing; the PATCH itself still touched only
    // one match.
    if (!sameMatches(patched.matches, propagated.matches)) {
      if (patched.version === undefined) throw new Error('the snapshot has no version')
      const saved = asClassic(
        await replaceTournament(slug, id, propagated, patched.version),
      )
      setSettled({ key, snapshot: saved, error: null })
      return
    }
    setSettled({ key, snapshot: patched, error: null })
  }

  const saveMetadata = async (name: string, date: string) => {
    if (snapshot === null || snapshot.version === undefined) {
      throw new Error('the snapshot has no version')
    }
    const saved = asClassic(
      await replaceTournament(
        slug,
        id,
        { ...snapshot, name, date },
        snapshot.version,
      ),
    )
    setSettled({ key, snapshot: saved, error: null })
  }

  const names = new Map((snapshot?.pairs ?? []).map((pair) => [pair.id, pair.name]))
  const nameOf = (pairId: string | null) =>
    pairId === null ? t('classic.tbd') : (names.get(pairId) ?? pairId)

  return (
    <section className="mx-auto max-w-5xl p-4">
      <Link
        to={`/c/${encodeURIComponent(slug)}/tournaments`}
        className="inline-flex min-h-11 items-center rounded-xl px-2 text-sm text-fg-dim hover:bg-elevated hover:text-fg focus-visible:ring-2 focus-visible:ring-accent"
      >
        {t('tournaments.title')}
      </Link>

      {loading && (
        <p role="status" className="mt-4 text-sm text-fg-dim">
          {t('app.loading')}
        </p>
      )}

      {loadError !== null && (
        <p role="alert" className="mt-4 text-sm text-error">
          {t(loadError)}
        </p>
      )}

      {snapshot !== null && (
        <>
          <h1 className="mt-2 text-xl font-bold text-fg sm:text-2xl">
            {snapshot.name}
          </h1>
          <p className="mt-1 font-mono text-xs text-fg-dim">{snapshot.date}</p>

          <MetadataForm
            // Remount only when a different tournament is opened; score saves
            // must not discard a name the user is still editing.
            key={snapshot.id ?? id}
            initialName={snapshot.name}
            initialDate={snapshot.date}
            onSave={saveMetadata}
          />

          <h2 className="mt-8 text-sm font-semibold text-fg">{t('classic.groups')}</h2>
          <div className="mt-2 grid gap-4 lg:grid-cols-2">
            {GROUP_IDS.map((groupId) => {
              const pairIds = snapshot.groups[groupId] ?? []
              const matches = snapshot.matches.filter(
                (match) => match.phase === 'group' && match.groupId === groupId,
              )
              return (
                <div
                  key={groupId}
                  className="rounded-2xl border border-border-subtle bg-ground p-3"
                >
                  <h3 className="text-sm font-semibold text-fg">
                    {t('classic.group', { group: groupId })}
                  </h3>
                  <StandingsTable
                    groupId={groupId}
                    pairIds={pairIds}
                    matches={snapshot.matches}
                    nameOf={nameOf}
                  />
                  <MatchList
                    matches={matches}
                    nameOf={nameOf}
                    onSave={saveScore}
                  />
                </div>
              )
            })}
          </div>

          <h2 className="mt-8 text-sm font-semibold text-fg">{t('classic.bracket')}</h2>
          {BRACKET_PHASES.map((phase) => {
            const matches = snapshot.matches.filter(
              (match) => match.phase === phase,
            )
            return (
              <div key={phase} className="mt-4">
                <h3 className="text-sm font-semibold text-fg">{phaseLabel(phase)}</h3>
                <MatchList
                  matches={matches}
                  nameOf={nameOf}
                  onSave={saveScore}
                />
              </div>
            )
          })}

          {isAdmin && (
            <AdminTools
              slug={slug}
              id={id}
              onDeleted={() =>
                navigate(`/c/${encodeURIComponent(slug)}/tournaments`)
              }
            />
          )}
        </>
      )}
    </section>
  )
}
