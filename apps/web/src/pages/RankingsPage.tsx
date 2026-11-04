import { Link, useParams, useSearchParams } from 'react-router-dom'
import { useCommunity } from '../community/CommunityContext'
import { t } from '../i18n'
import { TIERS } from '../rankings/api'
import { useRankings } from '../rankings/useRankings'

/** Unknown tier values fall back to the unfiltered board. */
function readTier(searchParams: URLSearchParams): string | null {
  const value = searchParams.get('tier')
  return value !== null && TIERS.includes(value) ? value : null
}

export default function RankingsPage() {
  const { slug = '' } = useParams<{ slug: string }>()
  const { memberships } = useCommunity()
  const membership = memberships.find((candidate) => candidate.slug === slug) ?? null
  const [searchParams, setSearchParams] = useSearchParams()
  const tier = readTier(searchParams)
  const { board, loading, error } = useRankings(slug === '' ? null : slug, tier)

  const selectTier = (value: string) => {
    const next = new URLSearchParams(searchParams)
    if (value === '') next.delete('tier')
    else next.set('tier', value)
    setSearchParams(next)
  }

  return (
    <section className="mx-auto max-w-3xl p-4">
      <h1 className="text-xl sm:text-2xl font-bold text-fg">{t('rankings.title')}</h1>
      <p className="mt-1 text-sm text-fg-dim">{membership?.name ?? slug}</p>
      <p className="mt-2 text-sm text-fg-dim">{t('rankings.subtitle')}</p>

      <div className="mt-4 flex items-center gap-2">
        <label htmlFor="rankings-tier" className="text-xs text-fg-dim">
          {t('rankings.filter.tier')}
        </label>
        <select
          id="rankings-tier"
          value={tier ?? ''}
          onChange={(event) => selectTier(event.target.value)}
          className="min-h-11 rounded-xl bg-elevated border border-border px-2 py-1.5 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
        >
          <option value="">{t('rankings.filter.all')}</option>
          {TIERS.map((value) => (
            <option key={value} value={value}>
              {value}
            </option>
          ))}
        </select>
      </div>

      {loading && (
        <p role="status" className="mt-4 text-sm text-fg-dim">
          {t('app.loading')}
        </p>
      )}

      {error === 'notFound' && (
        <p role="alert" aria-live="polite" className="mt-4 text-sm text-error">
          {t('rankings.error.notFound')}
        </p>
      )}
      {error === 'failed' && (
        <p role="alert" aria-live="polite" className="mt-4 text-sm text-error">
          {t('rankings.error.load')}
        </p>
      )}

      {board && board.items.length === 0 && (
        <p className="mt-4 text-sm text-fg-dim">{t('rankings.empty')}</p>
      )}

      {board && board.items.length > 0 && (
        <>
          <p className="mt-4 text-xs font-mono text-fg-dim">
            {t('rankings.asOf', { date: board.asOf })}
          </p>
          <div className="mt-2 overflow-x-auto rounded-2xl border border-border-subtle bg-surface">
            <table className="w-full border-collapse text-sm">
              <caption className="sr-only">{t('rankings.title')}</caption>
              <thead>
                <tr className="border-b border-border text-left text-xs text-fg-dim">
                  <th scope="col" className="px-3 py-2 font-semibold">
                    {t('rankings.column.rank')}
                  </th>
                  <th scope="col" className="px-3 py-2 font-semibold">
                    {t('rankings.column.player')}
                  </th>
                  <th scope="col" className="px-3 py-2 font-semibold">
                    {t('rankings.column.tier')}
                  </th>
                  <th scope="col" className="px-3 py-2 text-right font-semibold">
                    {t('rankings.column.points')}
                  </th>
                  <th scope="col" className="px-3 py-2 text-right font-semibold">
                    {t('rankings.column.games')}
                  </th>
                  <th scope="col" className="px-3 py-2 text-right font-semibold">
                    {t('rankings.column.wins')}
                  </th>
                  <th scope="col" className="px-3 py-2 text-right font-semibold">
                    {t('rankings.column.losses')}
                  </th>
                </tr>
              </thead>
              <tbody>
                {board.items.map((row) => (
                  <tr key={row.playerId} className="border-b border-border-subtle last:border-b-0">
                    <td className="px-3 py-2 font-mono text-fg-dim">{row.rank}</td>
                    <td className="px-3 py-2">
                      <Link
                        to={`/c/${encodeURIComponent(slug)}/rankings/${encodeURIComponent(row.playerId)}`}
                        className="rounded text-fg hover:text-accent focus-visible:ring-2 focus-visible:ring-accent"
                      >
                        {row.name}
                      </Link>
                    </td>
                    <td className="px-3 py-2 text-fg-dim">{row.tier ?? t('rankings.unrated')}</td>
                    <td className="px-3 py-2 text-right font-mono text-fg">{row.points}</td>
                    <td className="px-3 py-2 text-right font-mono text-fg-dim">{row.games}</td>
                    <td className="px-3 py-2 text-right font-mono text-fg-dim">{row.wins}</td>
                    <td className="px-3 py-2 text-right font-mono text-fg-dim">{row.losses}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </section>
  )
}
