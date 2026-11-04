import { Link, useParams } from 'react-router-dom'
import { useCommunity } from '../community/CommunityContext'
import { t } from '../i18n'
import { useSessions } from '../sessions/hooks'

/** Session list for one community. Read-only; editing lives on the detail page. */
export default function SessionsPage() {
  const { slug = '' } = useParams<{ slug: string }>()
  const { memberships } = useCommunity()
  const membership = memberships.find((candidate) => candidate.slug === slug) ?? null
  const { items, loading, error } = useSessions(slug === '' ? null : slug)

  return (
    <section className="mx-auto max-w-3xl p-4">
      <h1 className="text-xl font-bold text-fg sm:text-2xl">{t('sessions.title')}</h1>
      <p className="mt-1 text-sm text-fg-dim">{membership?.name ?? slug}</p>
      <p className="mt-2 text-sm text-fg-dim">{t('sessions.subtitle')}</p>

      {loading && (
        <p role="status" className="mt-4 text-sm text-fg-dim">
          {t('app.loading')}
        </p>
      )}

      {error === 'notFound' && (
        <p role="alert" className="mt-4 text-sm text-error">
          {t('sessions.error.notFound')}
        </p>
      )}
      {error === 'failed' && (
        <p role="alert" className="mt-4 text-sm text-error">
          {t('sessions.error.load')}
        </p>
      )}

      {items !== null && items.length === 0 && (
        <p className="mt-4 text-sm text-fg-dim">{t('sessions.empty')}</p>
      )}

      {items !== null && items.length > 0 && (
        <ul className="mt-4 space-y-2">
          {items.map((item) => (
            <li key={item.id}>
              <Link
                to={`/c/${encodeURIComponent(slug)}/sessions/${encodeURIComponent(item.id)}`}
                className="flex min-h-11 items-center justify-between gap-3 rounded-2xl border border-border-subtle bg-surface px-4 py-3 focus-visible:ring-2 focus-visible:ring-accent"
              >
                <span className="min-w-0">
                  <span className="block truncate text-sm font-semibold text-fg">
                    {item.title}
                  </span>
                  <span className="block font-mono text-xs text-fg-dim">{item.date}</span>
                </span>
                <span className="shrink-0 font-mono text-[10px] text-fg-dim uppercase">
                  {item.status}
                </span>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
