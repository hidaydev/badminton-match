import { Link, Outlet, useLocation, useNavigate, useParams } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import CommunityPicker from '../community/CommunityPicker'
import { useCommunity } from '../community/CommunityContext'
import { t } from '../i18n'

/** The v1 shell the club grew used to: a thin sticky header and one column. */
export default function HomeLayout() {
  const { slug = '' } = useParams<{ slug: string }>()
  const { current } = useCommunity()
  const { memberships, logout } = useAuth()
  const navigate = useNavigate()
  const location = useLocation()
  const base = `/c/${encodeURIComponent(slug)}`
  const isHome = location.pathname === base
  const role = current?.slug === slug ? current.role : null

  return (
    <div className="min-h-screen bg-ground text-fg flex flex-col">
      <header className="border-b border-border-subtle bg-surface sticky top-0 z-10 pt-[env(safe-area-inset-top)]">
        <div className="max-w-3xl mx-auto px-3 py-2.5 flex items-center gap-2">
          {!isHome && (
            <button
              type="button"
              onClick={() => navigate(-1)}
              className="p-1.5 -ml-1.5 rounded-lg text-fg-dim hover:text-fg active:scale-90 transition-all shrink-0"
              aria-label={t('shell.back')}
            >
              <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M15 18l-6-6 6-6" />
              </svg>
            </button>
          )}
          <Link to={base} className="flex items-center gap-2 min-w-0">
            <img src="/logo-192.png" alt={t('app.name')} className="w-6 h-6 shrink-0 object-contain" />
            <h1 className="text-sm font-bold text-fg tracking-tight whitespace-nowrap">{t('app.name').toUpperCase()}</h1>
            {current && (
              <span className="hidden sm:inline text-[10px] font-mono text-fg-dim truncate">
                {current.name}
              </span>
            )}
          </Link>

          <div className="ml-auto flex items-center gap-1 shrink-0">
            {memberships.length > 1 && (
              <div className="hidden sm:block">
                <CommunityPicker />
              </div>
            )}
            {role === 'admin' && (
              <Link
                to={`${base}/settings`}
                className="p-1.5 rounded-lg text-fg-dim hover:text-fg active:scale-90 transition-all"
                aria-label={t('nav.settings')}
              >
                <svg xmlns="http://www.w3.org/2000/svg" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" />
                </svg>
              </Link>
            )}
            <button
              type="button"
              onClick={() => window.location.reload()}
              className="p-1.5 rounded-lg text-fg-dim hover:text-fg active:scale-90 transition-all"
              aria-label={t('shell.refresh')}
            >
              <svg xmlns="http://www.w3.org/2000/svg" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8" />
                <path d="M21 3v5h-5" />
                <path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16" />
                <path d="M8 16H3v5" />
              </svg>
            </button>
            <button
              type="button"
              onClick={() => void logout().then(() => navigate('/'))}
              className="p-1.5 rounded-lg text-fg-dim hover:text-fg active:scale-90 transition-all"
              aria-label={t('nav.logout')}
            >
              <svg xmlns="http://www.w3.org/2000/svg" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
                <path d="M16 17l5-5-5-5" />
                <path d="M21 12H9" />
              </svg>
            </button>
          </div>
        </div>
      </header>
      <main className="flex-1 max-w-3xl w-full mx-auto px-3 py-4 relative pb-[env(safe-area-inset-bottom)]">
        <Outlet />
      </main>
    </div>
  )
}
