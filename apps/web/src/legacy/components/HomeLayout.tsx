import { useState } from 'react'
import { Link as RouterLink } from 'react-router-dom'
import { Link, Outlet, useLocation, useNavigate } from '../router'
import { useAdmin } from '../context/AdminContext'
import { useAuth } from '../../auth/AuthContext'
import { useCommunity } from '../../community/CommunityContext'
import CommunityPicker from '../../community/CommunityPicker'
import { t } from '../../i18n'
import AccountSessions from './AccountSessions'
import { useEscapeKey } from '../hooks/useEscapeKey'

export default function HomeLayout() {
  const location = useLocation()
  const navigate = useNavigate()
  const isHome = location.pathname === '/'
  const { isAdminRole } = useAdmin()
  const { user, logout } = useAuth()
  const { memberships, current, select } = useCommunity()
  const [accountOpen, setAccountOpen] = useState(false)
  const [sessionsOpen, setSessionsOpen] = useState(false)
  // The account menu is not a dialog: Escape closes the menu itself and nothing
  // behind it.
  useEscapeKey(() => setAccountOpen(false), accountOpen)

  const roleLabel = user?.platformOwner === true
    ? t('role.owner')
    : current === null
      ? ''
      : t(current.role === 'admin' ? 'role.admin' : current.role === 'host' ? 'role.host' : 'role.member')

  return (
    <div className="min-h-screen bg-ground text-fg flex flex-col">
      <header className="border-b border-border-subtle bg-surface sticky top-0 z-10 pt-[env(safe-area-inset-top)]">
        <div className="max-w-3xl mx-auto px-3 py-2.5 flex items-center gap-2">
          {!isHome && (
            <button
              onClick={() => navigate(-1)}
              className="p-1.5 -ml-1.5 rounded-lg text-fg-dim hover:text-fg active:scale-90 transition-all shrink-0 hit44"
              aria-label={t('shell.back')}
            >
              <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M15 18l-6-6 6-6"/>
              </svg>
            </button>
          )}
          <Link to="/" className="flex items-center gap-2 flex-1">
            <img src="/logo-192.png" alt="" className="w-6 h-6 shrink-0 object-contain" />
            <span className="text-sm font-bold text-fg tracking-tight">MAJADU</span>
          </Link>
          <div className="hidden sm:flex items-center gap-2">
            <CommunityPicker />
          </div>
          <button
            onClick={() => window.location.reload()}
            className="p-1.5 rounded-lg text-fg-dim hover:text-fg active:scale-90 transition-all hit44"
            aria-label={t('shell.refresh')}
          >
            <svg xmlns="http://www.w3.org/2000/svg" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/>
              <path d="M21 3v5h-5"/>
              <path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/>
              <path d="M8 16H3v5"/>
            </svg>
          </button>

          {/* Google login has no admin token: the account menu shows who is
              signed in and which role that account holds here. */}
          <div className="relative">
            <button
              type="button"
              onClick={() => setAccountOpen((open) => !open)}
              aria-label={t('shell.account')}
              aria-haspopup="menu"
              aria-expanded={accountOpen}
              className="flex h-8 w-8 items-center justify-center rounded-full border border-border bg-elevated text-xs font-bold text-fg hover:border-accent active:scale-95 transition-all hit44"
            >
              {(user?.displayName ?? '?').trim().charAt(0).toUpperCase()}
            </button>
            {accountOpen && (
              <>
                <button
                  type="button"
                  aria-hidden="true"
                  tabIndex={-1}
                  onClick={() => setAccountOpen(false)}
                  className="fixed inset-0 z-20 cursor-default min-h-11"
                />
                <div
                  role="menu"
                  className="absolute right-0 mt-2 z-30 w-60 overflow-hidden rounded-xl border border-border-subtle bg-surface shadow-lg"
                >
                  <div className="border-b border-border-subtle px-3 py-2.5">
                    <p className="truncate text-sm font-semibold text-fg">
                      {user?.displayName ?? ''}
                    </p>
                    <p className="mt-0.5 truncate text-[11px] text-fg-dim">
                      {roleLabel}
                      {current !== null ? ` · ${current.name}` : ''}
                    </p>
                  </div>
                  {/* The header picker is desktop-only; on phones the same
                      switch lives in this menu so members of several
                      communities can reach it. */}
                  {memberships.length > 1 && (
                    <div
                      role="group"
                      aria-label={t('community.label')}
                      className="border-b border-border-subtle p-1.5 sm:hidden"
                    >
                      <p className="px-3 pb-1 pt-1.5 text-[10px] font-semibold uppercase tracking-wider text-fg-dim">
                        {t('community.label')}
                      </p>
                      {memberships.map((membership) => {
                        const selected = membership.slug === current?.slug
                        return (
                          <button
                            key={membership.id}
                            role="menuitemradio"
                            aria-checked={selected}
                            type="button"
                            onClick={() => {
                              setAccountOpen(false)
                              select(membership.slug)
                            }}
                            className={`hit44 flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-sm ${
                              selected ? 'font-semibold text-accent' : 'text-fg hover:bg-elevated'
                            }`}
                          >
                            <span className="flex-1 truncate">{membership.name}</span>
                            {selected && (
                              <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                                <polyline points="20 6 9 17 4 12" />
                              </svg>
                            )}
                          </button>
                        )
                      })}
                    </div>
                  )}
                  <div className="flex flex-col p-1.5 text-sm">
                    {isAdminRole && (
                      <Link
                        role="menuitem"
                        to="/settings"
                        onClick={() => setAccountOpen(false)}
                        className="rounded-lg px-3 py-2 text-fg hover:bg-elevated"
                      >
                        {t('nav.settings')}
                      </Link>
                    )}
                    {user?.platformOwner === true && (
                      <RouterLink
                        role="menuitem"
                        to="/owner/communities"
                        onClick={() => setAccountOpen(false)}
                        className="rounded-lg px-3 py-2 text-fg hover:bg-elevated"
                      >
                        {t('nav.owner')}
                      </RouterLink>
                    )}
                    <button
                      role="menuitem"
                      type="button"
                      onClick={() => {
                        setAccountOpen(false)
                        setSessionsOpen(true)
                      }}
                      className="rounded-lg px-3 py-2 text-left text-fg hover:bg-elevated hit44"
                    >
                      {t('sessions.open')}
                    </button>
                    <button
                      role="menuitem"
                      type="button"
                      onClick={() => {
                        setAccountOpen(false)
                        void logout()
                      }}
                      className="rounded-lg px-3 py-2 text-left text-error/80 hover:bg-elevated hover:text-error hit44"
                    >
                      {t('nav.logout')}
                    </button>
                  </div>
                </div>
              </>
            )}
          </div>
        </div>
      </header>
      <main className="flex-1 max-w-3xl w-full mx-auto px-3 py-4 relative pb-[env(safe-area-inset-bottom)]">
        <Outlet />
      </main>
      {sessionsOpen && <AccountSessions onClose={() => setSessionsOpen(false)} />}
    </div>
  )
}
