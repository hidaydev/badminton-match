import { useNavigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import { t } from '../i18n'

export default function HomePage() {
  const { memberships } = useAuth()
  const navigate = useNavigate()

  if (memberships.length === 0) {
    return (
      <section className="mx-auto max-w-2xl p-4">
        <h1 className="text-xl sm:text-2xl font-bold text-fg">{t('home.empty')}</h1>
        <p className="mt-2 text-sm text-fg-dim">{t('home.emptyHint')}</p>
      </section>
    )
  }

  return (
    <section className="mx-auto max-w-2xl p-4">
      <h1 className="text-xl sm:text-2xl font-bold text-fg">{t('home.title')}</h1>
      <p className="mt-2 text-sm text-fg-dim">{t('home.subtitle')}</p>
      <ul className="mt-6 grid gap-3 sm:grid-cols-2">
        {memberships.map((membership) => (
          <li key={membership.id}>
            <button
              type="button"
              onClick={() => navigate(`/c/${membership.slug}/sessions`)}
              className="w-full min-h-11 rounded-xl bg-surface border border-border-subtle px-4 py-3 text-left text-fg hover:border-accent focus-visible:ring-2 focus-visible:ring-accent"
            >
              <span className="block text-sm font-semibold">{membership.name}</span>
              <span className="block text-xs text-fg-dim font-mono">{membership.slug}</span>
            </button>
          </li>
        ))}
      </ul>
    </section>
  )
}
