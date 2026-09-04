import { useState } from 'react'
import { Link, Outlet, useLocation, useNavigate } from 'react-router-dom'
import { useAdmin } from '../context/AdminContext'
import AdminLoginModal from './AdminLoginModal'
import { t } from '../i18n'

export default function HomeLayout() {
  const location = useLocation()
  const navigate = useNavigate()
  const isHome = location.pathname === '/'
  const { isAdmin, logout } = useAdmin()
  const [adminLoginOpen, setAdminLoginOpen] = useState(false)

  const handleAdminIconClick = () => {
    if (isAdmin) {
      if (window.confirm(t('admin.logoutConfirm'))) logout()
    } else {
      setAdminLoginOpen(true)
    }
  }

  return (
    <div className="min-h-screen bg-ground text-fg flex flex-col">
      <header className="border-b border-border-subtle bg-surface sticky top-0 z-10 pt-[env(safe-area-inset-top)]">
        <div className="max-w-3xl mx-auto px-3 py-2.5 flex items-center gap-2">
          {!isHome && (
            <button
              onClick={() => navigate(-1)}
              className="p-1.5 -ml-1.5 rounded-lg text-fg-dim hover:text-fg active:scale-90 transition-all shrink-0"
              aria-label="Back"
            >
              <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M15 18l-6-6 6-6"/>
              </svg>
            </button>
          )}
          <Link to="/" className="flex items-center gap-2 flex-1">
            <img src="/logo-192.png" alt="logo" className="w-6 h-6 shrink-0 object-contain" />
            <h1 className="text-sm font-bold text-fg tracking-tight">MAJADU</h1>
          </Link>
          {/* Admin icon — sebelah refresh */}
          <button
            onClick={handleAdminIconClick}
            className={`p-1.5 rounded-lg transition-all active:scale-90 ${
              isAdmin
                ? 'text-amber-400 hover:text-amber-300 bg-amber-900/30'
                : 'text-fg-dim hover:text-fg'
            }`}
            aria-label={isAdmin ? 'Admin (logged in)' : 'Admin login'}
          >
            {isAdmin ? (
              <svg xmlns="http://www.w3.org/2000/svg" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>
                <path d="m9 12 2 2 4-4"/>
              </svg>
            ) : (
              <svg xmlns="http://www.w3.org/2000/svg" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>
              </svg>
            )}
          </button>
          <button
            onClick={() => window.location.reload()}
            className="p-1.5 rounded-lg text-fg-dim hover:text-fg active:scale-90 transition-all"
            aria-label="Refresh"
          >
            <svg xmlns="http://www.w3.org/2000/svg" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/>
              <path d="M21 3v5h-5"/>
              <path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/>
              <path d="M8 16H3v5"/>
            </svg>
          </button>
        </div>
      </header>
      <main className="flex-1 max-w-3xl w-full mx-auto px-3 py-4 relative pb-[env(safe-area-inset-bottom)]">
        <Outlet />
      </main>
      <AdminLoginModal open={adminLoginOpen} onClose={() => setAdminLoginOpen(false)} />
    </div>
  )
}
