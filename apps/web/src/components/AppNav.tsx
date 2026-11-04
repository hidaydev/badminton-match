import { NavLink, useLocation, useNavigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import CommunityPicker from '../community/CommunityPicker'
import { t } from '../i18n'
import { communitySlugFromPath, visibleNav } from '../routes.manifest'

export default function AppNav() {
  const { user, memberships, logout } = useAuth()
  const location = useLocation()
  const navigate = useNavigate()

  const slug = communitySlugFromPath(location.pathname)
  const role = slug === null ? null : memberships.find((m) => m.slug === slug)?.role ?? null
  const items = visibleNav(role, user?.platformOwner === true)

  const withSlug = (path: string) => path.replace(':slug', slug ?? '')

  return (
    <header className="border-b border-border-subtle bg-surface">
      <div className="mx-auto max-w-5xl p-4 flex flex-wrap items-center gap-4">
        <span className="text-sm font-semibold text-accent">{t('app.name')}</span>
        <CommunityPicker />
        <nav aria-label={t('nav.group.main')} className="flex flex-wrap items-center gap-2">
          {items.map((item) => (
            <NavLink
              key={item.path}
              to={item.path.includes(':slug') ? withSlug(item.path) : item.path}
              className="min-h-11 inline-flex items-center rounded-xl px-3 text-sm text-fg-dim hover:text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent"
            >
              {t(item.labelKey)}
            </NavLink>
          ))}
        </nav>
        <div className="ml-auto flex items-center gap-3">
          {user && (
            <span className="text-xs text-fg-dim">
              {t('nav.signedInAs', { name: user.displayName })}
            </span>
          )}
          <button
            type="button"
            onClick={() => void logout().then(() => navigate('/'))}
            className="min-h-11 rounded-xl px-3 text-sm text-fg-dim hover:text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent"
          >
            {t('nav.logout')}
          </button>
        </div>
      </div>
    </header>
  )
}
