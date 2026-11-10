import { useEffect, useRef, useState } from 'react'
import { Link as RouterLink } from 'react-router-dom'
import { Link, Outlet, useLocation, useNavigate } from '../router'
import { useAdmin } from '../context/AdminContext'
import { useAuth } from '../../auth/AuthContext'
import { useCommunity } from '../../community/CommunityContext'
import { CommunityPicker } from '../../community/CommunityPicker'
import { t } from '../../i18n'
import { SkipLink } from '../../components/SkipLink'
import AccountSessions from './AccountSessions'
import Icon from '../../components/Icon'
import { PAGE_COLUMN } from '../../components/Page'

export default function HomeLayout() {
  const location = useLocation()
  const navigate = useNavigate()
  const isHome = location.pathname === '/'
  const { isAdminRole } = useAdmin()
  const { user, logout } = useAuth()
  const { memberships, current, select } = useCommunity()
  const [accountOpen, setAccountOpen] = useState(false)
  const [sessionsOpen, setSessionsOpen] = useState(false)
  const accountTrigger = useRef<HTMLButtonElement>(null)
  const accountMenu = useRef<HTMLDivElement>(null)

  // `role="menu"` is a keyboard promise: focus the first item on open, move
  // with the arrow keys, Home/End to the ends, and Escape closes the menu and
  // hands focus back to the trigger. Tab leaves the menu and closes it, like
  // any other popup that is not a dialog.
  // A hidden item cannot take focus, and focusing it would leave the menu with
  // no focused row at all. The community switch is `sm:hidden` where the header
  // picker already shows it, so it is in the DOM but not always in view.
  const menuItems = (): HTMLElement[] =>
    [...(accountMenu.current?.querySelectorAll<HTMLElement>('[role="menuitem"], [role="menuitemradio"]') ?? [])]
      .filter((item) => item.checkVisibility?.() !== false)

  const closeAccount = (refocus: boolean) => {
    setAccountOpen(false)
    if (refocus) accountTrigger.current?.focus()
  }

  useEffect(() => {
    if (!accountOpen) return
    menuItems()[0]?.focus()

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        closeAccount(true)
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [accountOpen])

  const onAccountMenuKeyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    if (event.key === 'Tab') {
      // Focus moves on to the page behind; an open menu there would trap the
      // next Shift+Tab in a place the user has already left.
      setAccountOpen(false)
      return
    }
    const items = menuItems()
    if (items.length === 0) return
    const index = items.indexOf(document.activeElement as HTMLElement)
    let next: HTMLElement | undefined
    if (event.key === 'ArrowDown') next = items[(index + 1) % items.length]
    else if (event.key === 'ArrowUp') next = items[(index - 1 + items.length) % items.length]
    else if (event.key === 'Home') next = items[0]
    else if (event.key === 'End') next = items[items.length - 1]
    if (next === undefined) return
    event.preventDefault()
    next.focus()
  }

  const roleLabel = user?.platformOwner === true
    ? t('role.owner')
    : current === null
      ? ''
      : t(current.role === 'admin' ? 'role.admin' : current.role === 'host' ? 'role.host' : 'role.member')

  return (
    <div className="min-h-screen bg-ground text-fg flex flex-col">
      <SkipLink />
      <header className="border-b border-border-subtle bg-surface sticky top-0 z-10 pt-[env(safe-area-inset-top)]">
        <div className={`${PAGE_COLUMN} py-2.5 flex items-center gap-2`}>
          {!isHome && (
            <button
              onClick={() => navigate(-1)}
              className="flex h-11 w-11 -ml-[13px] -mr-[7px] -my-[7px] items-center justify-center rounded-lg text-fg-dim hover:text-fg active:scale-90 transition-[color,transform] shrink-0"
              aria-label={t('shell.back')}
            >
              <Icon name="chevron-left" size={18} />
            </button>
          )}
          <Link to="/" className="flex min-h-11 -my-[10px] items-center gap-2 flex-1">
            <img src="/logo-192.png" alt="" className="w-6 h-6 shrink-0 object-contain" />
            <span className="text-sm font-bold text-fg tracking-tight">MAJADU</span>
          </Link>
          <div className="hidden sm:flex items-center gap-2">
            <CommunityPicker />
          </div>
          <button
            onClick={() => window.location.reload()}
            className="flex h-11 w-11 -m-[7.5px] items-center justify-center rounded-lg text-fg-dim hover:text-fg active:scale-90 transition-[color,transform]"
            aria-label={t('shell.refresh')}
          >
            <Icon name="sync" size={17} />
          </button>

          {/* Google login has no admin token: the account menu shows who is
              signed in and which role that account holds here. */}
          <div className="relative">
            <button
              ref={accountTrigger}
              type="button"
              onClick={() => setAccountOpen((open) => !open)}
              aria-label={t('shell.account')}
              aria-haspopup="menu"
              aria-expanded={accountOpen}
              className="group flex h-11 w-11 -m-[6px] items-center justify-center active:scale-95 transition-[transform]"
            >
              {/* The hit box grew to 44px; the circle itself keeps its 32px
                  size, so nothing on screen moved. */}
              <span
                aria-hidden="true"
                className="flex h-8 w-8 items-center justify-center rounded-full border border-border bg-elevated text-xs font-bold text-fg group-hover:border-accent"
              >
                {(user?.displayName ?? '?').trim().charAt(0).toUpperCase()}
              </span>
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
                  ref={accountMenu}
                  role="menu"
                  aria-label={t('shell.account')}
                  onKeyDown={onAccountMenuKeyDown}
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
                      <p className="px-3 pb-1 pt-1.5 text-[10px] font-semibold label-meta text-fg-dim">
                        {t('community.label')}
                      </p>
                      {memberships.map((membership) => {
                        const selected = membership.slug === current?.slug
                        return (
                          <button
                            key={membership.id}
                            role="menuitemradio"
                            aria-checked={selected}
                            tabIndex={-1}
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
                              <Icon name="check" size={14} />
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
                        tabIndex={-1}
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
                        tabIndex={-1}
                        to="/owner/communities"
                        onClick={() => setAccountOpen(false)}
                        className="rounded-lg px-3 py-2 text-fg hover:bg-elevated"
                      >
                        {t('nav.owner')}
                      </RouterLink>
                    )}
                    <button
                      role="menuitem"
                      tabIndex={-1}
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
                      tabIndex={-1}
                      type="button"
                      onClick={() => {
                        setAccountOpen(false)
                        void logout()
                      }}
                      className="rounded-lg px-3 py-2 text-left text-error hover:bg-elevated hover:text-error hit44"
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
      <main id="main" className={`flex-1 ${PAGE_COLUMN} py-4 relative pb-[env(safe-area-inset-bottom)]`}>
        <Outlet />
      </main>
      {sessionsOpen && <AccountSessions onClose={() => setSessionsOpen(false)} />}
    </div>
  )
}
