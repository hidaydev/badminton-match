import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { AuthProvider } from './auth/AuthProvider'
import { useAuth } from './auth/AuthContext'
import ClientOutdatedBanner from './components/ClientOutdatedBanner'
import AppNav from './components/AppNav'
import { CommunityProvider } from './community/CommunityProvider'
import { t } from './i18n'
import LoginPage from './pages/LoginPage'
import { routes } from './routes.manifest'
import type { RouteEntry } from './routes.manifest'

function Loading() {
  return (
    <div className="min-h-screen bg-ground text-fg flex items-center justify-center">
      <span className="text-sm text-fg-dim">{t('app.loading')}</span>
    </div>
  )
}

/** Public entries (shared session links) render outside the session gate. */
function RouteElement({ route }: { route: RouteEntry }) {
  const { user, loading } = useAuth()
  if (!route.requiresAuth) return route.element
  if (loading) return <Loading />
  if (!user) return <LoginPage />
  return route.element
}

function Shell() {
  const { user } = useAuth()
  return (
    <div className="min-h-screen bg-ground text-fg">
      <ClientOutdatedBanner />
      {user && <AppNav />}
      <main>
        <Routes>
          {routes.map((route) => (
            <Route
              key={route.path}
              path={route.path}
              element={<RouteElement route={route} />}
            />
          ))}
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>
    </div>
  )
}

export default function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <CommunityProvider>
          <Shell />
        </CommunityProvider>
      </BrowserRouter>
    </AuthProvider>
  )
}
