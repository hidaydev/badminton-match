import { useState } from 'react'
import { NavLink, useLocation, useNavigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import CommunityPicker from '../community/CommunityPicker'
import { t } from '../i18n'
import { communitySlugFromPath, visibleNav } from '../routes.manifest'

export default function AppNav() {
  const { user, memberships, logout } = useAuth()
  const location = useLocation()
  const navigate = useNavigate()
  // The menu is open for one path only, so navigating closes it without an
  // effect that would set state during render.
  const [openPath, setOpenPath] = useState<string | null>(null)

  const slug = communitySlugFromPath(location.pathname)
  const role = slug === null ? null : memberships.find((m) => m.slug === slug)?.role ?? null
  const items = visibleNav(role, user?.platformOwner === true)

  const open = openPath === location.pathname
  const withSlug = (path: string) => path.replace(':slug', slug ?? '')

  return (
    <header className="border-b border-border-subtle bg-surface">
      <div className="mx-auto flex max-w-5xl flex-col p-4 sm:flex-row sm:items-center sm:gap-4">
        <div className="flex items-center gap-4">
          <span className="text-sm font-semibold text-accent">{t('app.name')}</span>
          <button
            type="button"
            aria-expanded={open}
            aria-controls="app-nav"
            onClick={() => setOpenPath(open ? null : location.pathname)}
            className="ml-auto min-h-11 rounded-xl border border-border px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent sm:hidden"
          >
            {t(open ? 'nav.menu.close' : 'nav.menu')}
          </button>
        </div>
        <div
          id="app-nav"
          className={`${
            open ? 'flex' : 'hidden'
          } flex-col gap-3 pt-3 sm:flex sm:flex-row sm:items-center sm:gap-4 sm:pt-0`}
        >
          <CommunityPicker />
          <nav
            aria-label={t('nav.group.main')}
            className="flex flex-col gap-1 sm:flex-row sm:items-center sm:gap-2"
          >
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
          <div className="flex flex-col gap-1 sm:ml-auto sm:flex-row sm:items-center sm:gap-3">
            {user && (
              <span className="text-xs text-fg-dim">
                {t('nav.signedInAs', { name: user.displayName })}
              </span>
            )}
            <button
              type="button"
              onClick={() => void logout().then(() => navigate('/'))}
              className="min-h-11 rounded-xl px-3 text-sm text-fg-dim hover:text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent text-left"
            >
              {t('nav.logout')}
            </button>
          </div>
        </div>
      </div>
    </header>
  )
}
