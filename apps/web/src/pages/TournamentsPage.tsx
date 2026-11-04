import { useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { ApiError } from '../auth/api'
import { useCommunity } from '../community/CommunityContext'
import { t } from '../i18n'
import { listTournaments } from '../tournament/api'
import type { TournamentMeta } from '../tournament/types'

type Settled = {
  /** Slug the settled response belongs to, so a stale reply is never shown. */
  key: string | null
  items: TournamentMeta[] | null
  error: 'notFound' | 'failed' | null
}

const UNRESOLVED: Settled = { key: null, items: null, error: null }

/** Index of both formats; each row links to the editor that matches it. */
export default function TournamentsPage() {
  const { slug = '' } = useParams<{ slug: string }>()
  const { memberships } = useCommunity()
  const membership = memberships.find((candidate) => candidate.slug === slug) ?? null
  const [settled, setSettled] = useState<Settled>(UNRESOLVED)

  useEffect(() => {
    if (slug === '') return
    const key = slug
    let active = true
    listTournaments(slug)
      .then((items) => {
        if (active) setSettled({ key, items, error: null })
      })
      .catch((error: unknown) => {
        if (!active) return
        const kind =
          error instanceof ApiError && error.status === 404 ? 'notFound' : 'failed'
        setSettled({ key, items: null, error: kind })
      })
    return () => {
      active = false
    }
  }, [slug])

  const current = slug !== '' && settled.key === slug
  const items = current ? settled.items : null
  const error = current ? settled.error : null
  const loading = slug !== '' && !current

  const prefix = `/c/${encodeURIComponent(slug)}/tournaments`

  return (
    <section className="mx-auto max-w-3xl p-4">
      <h1 className="text-xl sm:text-2xl font-bold text-fg">{t('tournaments.title')}</h1>
      <p className="mt-1 text-sm text-fg-dim">{membership?.name ?? slug}</p>
      <p className="mt-2 text-sm text-fg-dim">{t('tournaments.subtitle')}</p>

      <div className="mt-4 flex flex-wrap gap-2">
        <Link
          to={`${prefix}/classic/new`}
          className="min-h-11 rounded-xl bg-accent px-4 py-2 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent"
        >
          {t('tournaments.newClassic')}
        </Link>
        <Link
          to={`${prefix}/team/new`}
          className="min-h-11 rounded-xl border border-border px-4 py-2 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
        >
          {t('tournaments.newTeam')}
        </Link>
      </div>

      {loading && (
        <p role="status" className="mt-4 text-sm text-fg-dim">
          {t('app.loading')}
        </p>
      )}

      {error === 'notFound' && (
        <p role="alert" className="mt-4 text-sm text-error">
          {t('tournaments.error.notFound')}
        </p>
      )}
      {error === 'failed' && (
        <p role="alert" className="mt-4 text-sm text-error">
          {t('tournaments.error.load')}
        </p>
      )}

      {items !== null && items.length === 0 && (
        <p className="mt-6 text-sm text-fg-dim">{t('tournaments.empty')}</p>
      )}

      {items !== null && items.length > 0 && (
        <table className="mt-6 w-full text-left text-sm">
          <caption className="sr-only">{t('tournaments.title')}</caption>
          <thead className="text-xs text-fg-dim">
            <tr>
              <th scope="col" className="py-2">{t('tournaments.column.name')}</th>
              <th scope="col" className="py-2">{t('tournaments.column.date')}</th>
              <th scope="col" className="py-2">{t('tournaments.column.format')}</th>
              <th scope="col" className="py-2">{t('tournaments.column.status')}</th>
            </tr>
          </thead>
          <tbody>
            {items.map((item) => (
              <tr key={item.id} className="border-t border-border-subtle">
                <td className="py-2">
                  <Link
                    to={`${prefix}/${item.format}/${encodeURIComponent(item.id)}`}
                    className="text-fg underline-offset-4 hover:underline focus-visible:ring-2 focus-visible:ring-accent"
                  >
                    {item.name}
                  </Link>
                </td>
                <td className="py-2 text-fg-dim">{item.date}</td>
                <td className="py-2 text-fg-dim">
                  {item.format === 'team'
                    ? t('tournaments.format.team')
                    : t('tournaments.format.classic')}
                </td>
                <td className="py-2 text-fg-dim">{item.status}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}
