import { useEffect, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { ApiError } from '../auth/api'
import { useCommunity } from '../community/CommunityContext'
import { t } from '../i18n'
import type { MessageKey } from '../i18n/en'
import {
  deleteTournament,
  finalizeSource,
  getTournament,
  ingestTournamentRating,
  patchTeamMatch,
  replaceTournament,
  revertTournamentRating,
} from '../tournament/api'
import type { RatingIngest } from '../tournament/api'
import { isTeam } from '../tournament/types'
import type { TeamMatch, TeamSnapshot } from '../tournament/types'
import TeamMatchCard from '../tournament/team/TeamMatchCard'
import TeamNewForm from '../tournament/team/TeamNewForm'
import TeamStandings from '../tournament/team/TeamStandings'
import {
  champion,
  computeStandings,
  drawGroupMatches,
  finalMatch,
  groupMatches,
  isGroupComplete,
  teamsById,
} from '../tournament/team/rules'
import type { TeamMatchPatch } from '../tournament/team/rules'

type LoadError = 'notFound' | 'failed'

type Settled = {
  /** Slug + id the settled response belongs to, so a stale reply is skipped. */
  key: string | null
  snapshot: TeamSnapshot | null
  error: LoadError | null
}

const UNRESOLVED: Settled = { key: null, snapshot: null, error: null }

const linkClass =
  'inline-flex min-h-11 items-center rounded-xl px-2 text-sm text-fg-dim hover:text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent'
const primaryClass =
  'min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground disabled:opacity-40 focus-visible:ring-2 focus-visible:ring-accent'
const secondaryClass =
  'min-h-11 rounded-xl border border-border px-4 text-sm text-fg disabled:opacity-40 focus-visible:ring-2 focus-visible:ring-accent'
const dangerClass =
  'min-h-11 rounded-xl border border-error px-4 text-sm text-error disabled:opacity-40 focus-visible:ring-2 focus-visible:ring-error'

/** 412 is a lost version race, 400 is a rejected body, anything else generic. */
function writeFailure(error: unknown): MessageKey {
  if (error instanceof ApiError) {
    if (error.status === 412) return 'tournament.error.conflict'
    if (error.status === 400) return 'team.error.invalid'
  }
  return 'tournament.error.invalid'
}

type CourtSection = { court: string; matches: TeamMatch[] }

/** The fixed draw puts three matches on each court, so a court is a session. */
function byCourt(matches: readonly TeamMatch[]): CourtSection[] {
  const sections: CourtSection[] = []
  for (const match of matches) {
    const court = match.courts[0]
    const section = sections.find((candidate) => candidate.court === court)
    if (section === undefined) sections.push({ court, matches: [match] })
    else section.matches.push(match)
  }
  return sections
}

export default function TournamentTeamPage() {
  const { slug = '', id } = useParams<{ slug: string; id: string }>()
  const { memberships } = useCommunity()
  const membership = memberships.find((candidate) => candidate.slug === slug) ?? null
  const navigate = useNavigate()

  const tournamentId = id ?? ''
  const isNew = tournamentId === ''
  const requestKey =
    isNew || slug === '' ? null : `${slug}\u0000${tournamentId}`

  const [settled, setSettled] = useState<Settled>(UNRESOLVED)
  const [busy, setBusy] = useState(false)
  const [saved, setSaved] = useState(false)
  const [structureError, setStructureError] = useState<MessageKey | null>(null)
  const [ratingError, setRatingError] = useState<MessageKey | null>(null)
  const [finalized, setFinalized] = useState(false)
  const [rated, setRated] = useState<RatingIngest | null>(null)

  useEffect(() => {
    if (requestKey === null) return
    let active = true

    getTournament(slug, tournamentId)
      .then((tournament) => {
        if (!active) return
        if (!isTeam(tournament)) {
          setSettled({ key: requestKey, snapshot: null, error: 'notFound' })
          return
        }
        setSettled({ key: requestKey, snapshot: tournament, error: null })
      })
      .catch((error: unknown) => {
        if (!active) return
        const kind: LoadError =
          error instanceof ApiError && error.status === 404 ? 'notFound' : 'failed'
        setSettled({ key: requestKey, snapshot: null, error: kind })
      })

    return () => {
      active = false
    }
  }, [slug, tournamentId, requestKey])

  const current = requestKey !== null && settled.key === requestKey
  const snapshot = current ? settled.snapshot : null
  const loading = requestKey !== null && !current
  const loadError = current ? settled.error : null

  const apply = (next: TeamSnapshot) => {
    if (requestKey === null) return
    setSettled({ key: requestKey, snapshot: next, error: null })
  }

  const saveMatch = async (
    matchId: string,
    patch: TeamMatchPatch,
  ): Promise<MessageKey | null> => {
    if (snapshot === null) return 'tournament.error.invalid'
    setSaved(false)
    try {
      const next = await patchTeamMatch(
        slug,
        tournamentId,
        matchId,
        patch,
        snapshot.version ?? 0,
      )
      if (!isTeam(next)) return 'tournament.error.invalid'
      apply(next)
      setSaved(true)
      return null
    } catch (error) {
      return writeFailure(error)
    }
  }

  const drawGroups = async () => {
    if (snapshot === null) return
    setSaved(false)
    setStructureError(null)
    setBusy(true)
    try {
      const next = await replaceTournament(
        slug,
        tournamentId,
        {
          ...snapshot,
          matches: drawGroupMatches(snapshot.teams.map((team) => team.id)),
        },
        snapshot.version ?? 0,
      )
      if (!isTeam(next)) {
        setStructureError('tournament.error.invalid')
        return
      }
      apply(next)
    } catch (error) {
      setStructureError(writeFailure(error))
    } finally {
      setBusy(false)
    }
  }

  const createFinal = async () => {
    if (snapshot === null) return
    const top = computeStandings(snapshot.teams, groupMatches(snapshot)).slice(0, 2)
    if (top.length < 2) return
    setSaved(false)
    setStructureError(null)
    setBusy(true)
    try {
      const next = await replaceTournament(
        slug,
        tournamentId,
        {
          ...snapshot,
          matches: [
            ...snapshot.matches,
            finalMatch(top[0].teamId, top[1].teamId),
          ],
        },
        snapshot.version ?? 0,
      )
      if (!isTeam(next)) {
        setStructureError('tournament.error.invalid')
        return
      }
      apply(next)
    } catch (error) {
      setStructureError(writeFailure(error))
    } finally {
      setBusy(false)
    }
  }

  const signOff = async () => {
    setRatingError(null)
    setBusy(true)
    try {
      await finalizeSource(slug, tournamentId, true)
      setFinalized(true)
    } catch (error) {
      setRatingError(writeFailure(error))
    } finally {
      setBusy(false)
    }
  }

  const rate = async () => {
    setRatingError(null)
    setBusy(true)
    try {
      const result = await ingestTournamentRating(slug, tournamentId)
      setRated(result)
    } catch (error) {
      if (error instanceof ApiError && error.status === 400 && error.code === 'INVALID_STATE') {
        setRatingError('team.rating.finalize')
      } else {
        setRatingError(writeFailure(error))
      }
    } finally {
      setBusy(false)
    }
  }

  const revertRating = async () => {
    setRatingError(null)
    setBusy(true)
    try {
      await revertTournamentRating(slug, tournamentId)
      setRated(null)
    } catch (error) {
      if (error instanceof ApiError && error.status === 403) {
        setRatingError('team.rating.finalized')
      } else {
        setRatingError(writeFailure(error))
      }
    } finally {
      setBusy(false)
    }
  }

  const remove = async () => {
    if (!window.confirm(t('tournaments.deleteConfirm'))) return
    setRatingError(null)
    setBusy(true)
    try {
      await deleteTournament(slug, tournamentId)
      navigate(`/c/${encodeURIComponent(slug)}/tournaments`)
    } catch (error) {
      setRatingError(writeFailure(error))
      setBusy(false)
    }
  }

  const names = snapshot === null ? new Map<string, string>() : teamsById(snapshot.teams)
  const teamName = (teamId: string) => names.get(teamId) ?? teamId
  const group = snapshot === null ? [] : groupMatches(snapshot)
  const finals = snapshot === null
    ? []
    : snapshot.matches.filter((match) => match.phase === 'final')
  const final = finals.length > 0 ? finals[0] : null
  const standings = snapshot === null ? [] : computeStandings(snapshot.teams, group)
  const groupDone = snapshot !== null && isGroupComplete(snapshot)
  const winner = snapshot === null ? null : champion(snapshot)

  return (
    <section className="mx-auto max-w-3xl p-4">
      <Link to={`/c/${encodeURIComponent(slug)}/tournaments`} className={linkClass}>
        {t('nav.tournaments')}
      </Link>

      {isNew ? (
        <>
          <h1 className="mt-2 text-xl sm:text-2xl font-bold text-fg">
            {t('tournaments.newTeam')}
          </h1>
          <TeamNewForm slug={slug} />
        </>
      ) : (
        <>
          {loading && (
            <p role="status" className="mt-4 text-sm text-fg-dim">
              {t('app.loading')}
            </p>
          )}

          {loadError === 'notFound' && (
            <p role="alert" aria-live="polite" className="mt-4 text-sm text-error">
              {t('tournaments.error.notFound')}
            </p>
          )}
          {loadError === 'failed' && (
            <p role="alert" aria-live="polite" className="mt-4 text-sm text-error">
              {t('tournament.error.load')}
            </p>
          )}

          {snapshot !== null && (
            <>
              <h1 className="mt-2 text-xl sm:text-2xl font-bold text-fg">{snapshot.name}</h1>
              <p className="mt-1 text-sm text-fg-dim">{snapshot.date}</p>

              <h2 className="mt-6 text-sm font-semibold text-fg">{t('team.teams')}</h2>
              <dl className="mt-2 grid gap-3 sm:grid-cols-2">
                {snapshot.teams.map((team) => (
                  <div
                    key={team.id}
                    className="rounded-2xl border border-border-subtle bg-surface p-3"
                  >
                    <dt className="text-sm font-semibold text-fg">{team.name}</dt>
                    <dd className="mt-1">
                      <ul className="space-y-1">
                        {team.players.map((player) => (
                          <li
                            key={`${player.cls}:${player.name}`}
                            className="flex items-baseline justify-between gap-2 text-sm"
                          >
                            <span className="text-fg-dim">{player.name}</span>
                            <span className="font-mono text-xs text-accent">
                              {player.cls}
                            </span>
                          </li>
                        ))}
                      </ul>
                    </dd>
                  </div>
                ))}
              </dl>

              <h2 className="mt-6 text-sm font-semibold text-fg">
                {t('team.schedule')}
              </h2>
              {saved && (
                <p role="status" className="mt-1 text-sm text-success">
                  {t('tournament.saved')}
                </p>
              )}
              {structureError !== null && (
                <p role="alert" aria-live="polite" className="mt-1 text-sm text-error">
                  {t(structureError)}
                </p>
              )}

              {group.length === 0 ? (
                <div className="mt-2">
                  <p className="text-sm text-fg-dim">{t('classic.drawHint')}</p>
                  <button
                    type="button"
                    onClick={() => void drawGroups()}
                    disabled={busy}
                    className={`mt-2 ${primaryClass}`}
                  >
                    {t('classic.draw')}
                  </button>
                </div>
              ) : (
                byCourt(group).map((section) => (
                  <section key={section.court} className="mt-4">
                    <h3 className="text-xs font-mono uppercase tracking-wide text-fg-dim">
                      {section.court}
                    </h3>
                    <div className="mt-2 space-y-3">
                      {section.matches.map((match) => (
                        <TeamMatchCard
                          key={`${match.id}:${snapshot.version ?? 0}`}
                          match={match}
                          teamName={teamName}
                          onSave={saveMatch}
                        />
                      ))}
                    </div>
                  </section>
                ))
              )}

              <h2 className="mt-6 text-sm font-semibold text-fg">{t('team.final')}</h2>
              {final !== null ? (
                <div className="mt-2">
                  <TeamMatchCard
                    key={`${final.id}:${snapshot.version ?? 0}`}
                    match={final}
                    teamName={teamName}
                    onSave={saveMatch}
                  />
                </div>
              ) : groupDone ? (
                <button
                  type="button"
                  onClick={() => void createFinal()}
                  disabled={busy}
                  className={`mt-2 ${primaryClass}`}
                >
                  {t('team.createFinal')}
                </button>
              ) : (
                <p className="mt-2 text-sm text-fg-dim">{t('classic.tbd')}</p>
              )}

              {winner !== null && (
                <p role="status" className="mt-2 text-sm text-fg">
                  {t('team.champion')}:{' '}
                  <span className="font-semibold text-accent">{teamName(winner)}</span>
                </p>
              )}

              <h2 className="mt-6 text-sm font-semibold text-fg">
                {t('team.standings')}
              </h2>
              <TeamStandings standings={standings} />

              {membership?.role === 'admin' && (
                <section className="mt-6 rounded-2xl border border-border-subtle bg-surface p-4">
                  <h2 className="text-sm font-semibold text-fg">{t('role.admin')}</h2>
                  <div className="mt-3 flex flex-wrap gap-2">
                    <button
                      type="button"
                      onClick={() => void signOff()}
                      disabled={busy || finalized}
                      className={secondaryClass}
                    >
                      {t('team.rating.finalize')}
                    </button>
                    <button
                      type="button"
                      onClick={() => void rate()}
                      disabled={busy}
                      className={secondaryClass}
                    >
                      {t('team.rating.ingest')}
                    </button>
                    <button
                      type="button"
                      onClick={() => void revertRating()}
                      disabled={busy}
                      className={secondaryClass}
                    >
                      {t('team.rating.revert')}
                    </button>
                    <button
                      type="button"
                      onClick={() => void remove()}
                      disabled={busy}
                      className={dangerClass}
                    >
                      {t('tournaments.delete')}
                    </button>
                  </div>

                  {finalized && (
                    <p role="status" className="mt-2 text-sm text-success">
                      {t('team.rating.finalized')}
                    </p>
                  )}
                  {rated !== null && (
                    <p role="status" className="mt-2 text-sm text-success">
                      {t('team.rating.done', {
                        events: rated.events,
                        deltas: rated.deltas,
                      })}
                    </p>
                  )}
                  {ratingError !== null && (
                    <p role="alert" aria-live="polite" className="mt-2 text-sm text-error">
                      {t(ratingError)}
                    </p>
                  )}
                </section>
              )}
            </>
          )}
        </>
      )}
    </section>
  )
}
