import { Link, useLocation, useParams } from 'react-router-dom'
import { t } from '../i18n'
import type { MessageKey } from '../i18n/en'
import { usePlayerProfile } from '../rankings/usePlayerProfile'
import { formatDay } from '../utils/day'

function genderKey(gender: string | null): MessageKey {
  if (gender === 'M') return 'player.gender.male'
  if (gender === 'F') return 'player.gender.female'
  return 'player.gender.unknown'
}

export default function RatingPlayerPage() {
  const { slug = '', playerId = '' } = useParams<{ slug: string; playerId: string }>()
  const location = useLocation()
  const known = slug !== '' && playerId !== ''
  const { profile, loading, error } = usePlayerProfile(
    known ? slug : null,
    known ? playerId : null,
  )

  return (
    <section className="mx-auto max-w-2xl p-4">
      <Link
        to={`/c/${encodeURIComponent(slug)}/rankings${location.search}`}
        className="inline-flex min-h-11 items-center rounded-xl px-2 text-sm text-fg-dim hover:text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent"
      >
        {t('player.back')}
      </Link>

      {loading && (
        <p role="status" className="mt-4 text-sm text-fg-dim">
          {t('app.loading')}
        </p>
      )}

      {error === 'notFound' && (
        <p role="alert" aria-live="polite" className="mt-4 text-sm text-error">
          {t('player.error.notFound')}
        </p>
      )}
      {error === 'failed' && (
        <p role="alert" aria-live="polite" className="mt-4 text-sm text-error">
          {t('player.error.load')}
        </p>
      )}

      {profile && (
        <>
          <h1 className="mt-4 text-xl sm:text-2xl font-bold text-fg">{profile.row.name}</h1>
          <div className="mt-2 flex flex-wrap items-center gap-2 text-sm text-fg-dim">
            <span className="rounded-lg border border-border bg-elevated px-2 py-0.5">
              {profile.row.tier ?? t('rankings.unrated')}
            </span>
            <span className="font-mono">{t('player.rank', { rank: profile.row.rank })}</span>
          </div>

          <h2 className="mt-6 text-sm font-semibold text-fg">{t('player.stats')}</h2>
          <dl className="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-3">
            <div className="rounded-2xl border border-border-subtle bg-surface p-3">
              <dt className="text-xs text-fg-dim">{t('player.stats.points')}</dt>
              <dd className="mt-1 font-mono text-sm text-fg">{profile.stats.points}</dd>
            </div>
            <div className="rounded-2xl border border-border-subtle bg-surface p-3">
              <dt className="text-xs text-fg-dim">{t('player.stats.games')}</dt>
              <dd className="mt-1 font-mono text-sm text-fg">{profile.stats.games}</dd>
            </div>
            <div className="rounded-2xl border border-border-subtle bg-surface p-3">
              <dt className="text-xs text-fg-dim">{t('player.stats.wins')}</dt>
              <dd className="mt-1 font-mono text-sm text-fg">{profile.stats.wins}</dd>
            </div>
            <div className="rounded-2xl border border-border-subtle bg-surface p-3">
              <dt className="text-xs text-fg-dim">{t('player.stats.losses')}</dt>
              <dd className="mt-1 font-mono text-sm text-fg">{profile.stats.losses}</dd>
            </div>
            <div className="rounded-2xl border border-border-subtle bg-surface p-3">
              <dt className="text-xs text-fg-dim">{t('player.stats.gender')}</dt>
              <dd className="mt-1 text-sm text-fg">{t(genderKey(profile.stats.gender))}</dd>
            </div>
          </dl>

          <h2 className="mt-6 text-sm font-semibold text-fg">{t('player.badges')}</h2>
          {profile.achievements.length === 0 ? (
            <p className="mt-3 text-sm text-fg-dim">{t('player.badges.empty')}</p>
          ) : (
            <ul className="mt-3 grid gap-3 sm:grid-cols-2">
              {profile.achievements.map((badge) => (
                <li
                  key={badge.key}
                  className="rounded-2xl border border-border-subtle bg-surface p-4"
                >
                  <p className="font-mono text-sm text-fg">{badge.key}</p>
                  <p className="mt-1 text-xs text-fg-dim">{badge.category}</p>
                  <p className="mt-1 text-xs text-fg-dim">
                    {t('player.badge.threshold', { threshold: badge.threshold })}
                  </p>
                  <p className="mt-1 text-xs font-mono text-fg-dim">
                    {t('player.badge.earned', { date: formatDay(badge.earnedAt) })}
                  </p>
                </li>
              ))}
            </ul>
          )}
        </>
      )}
    </section>
  )
}
