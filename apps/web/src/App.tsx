import { useState, useCallback, useMemo, lazy, Suspense } from 'react'
import { AdminProvider } from './context/AdminContext'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { useRegisterSW } from 'virtual:pwa-register/react'
import UpdateBanner from './components/UpdateBanner'
import ErrorBoundary from './components/ErrorBoundary'
import HomeLayout from './components/HomeLayout'
import SessionLayout from './components/SessionLayout'
import HomePage from './pages/HomePage'
import SetupPage from './pages/SetupPage'
import PlayersPage from './pages/PlayersPage'
import ConstraintsPage from './pages/ConstraintsPage'
import GeneratePage from './pages/GeneratePage'
import SessionListPage from './pages/SessionListPage'
import { useStore } from './store'
import { decodeSnapshot, type SharedSnapshot } from './utils/shareUrl'
import { SharedViewContext, useSharedView } from './sharedView'

// Lazy-loaded heavy pages (code-split)
const ScoreboardPage = lazy(() => import('./pages/ScoreboardPage'))
const InstagramPostPage = lazy(() => import('./pages/InstagramPostPage'))
const TournamentPage = lazy(() => import('./pages/TournamentRouter'))
const TournamentListPage = lazy(() => import('./pages/TournamentListPage'))
const RatingsPage = lazy(() => import('./pages/RatingsPage'))
const AdminSessionsPage = lazy(() => import('./pages/admin/AdminSessionsPage'))
const AdminPlayersPage = lazy(() => import('./pages/admin/AdminPlayersPage'))
const AdminRatingsPage = lazy(() => import('./pages/admin/AdminRatingsPage'))
const AdminTournamentsPage = lazy(() => import('./pages/admin/AdminTournamentsPage'))
const AdminSeasonsPage = lazy(() => import('./pages/admin/AdminSeasonsPage'))
const RatingPlayerPage = lazy(() => import('./pages/RatingPlayerPage'))
const NewTournamentPage = lazy(() => import('./pages/NewTournamentPage'))
const NewTournamentWizard = lazy(() => import('./pages/NewTournamentWizard'))
const SharedSessionPage = lazy(() => import('./pages/SharedSessionPage'))

function Loading() {
  return (
    <div className="min-h-screen bg-ground text-fg flex items-center justify-center">
      <span className="text-fg-dim text-sm">Loading…</span>
    </div>
  )
}

function RequireSession({ children }: { children: React.ReactNode }) {
  const locked = useStore((s) => s.session.locked)
  return locked ? <>{children}</> : <Navigate to="/session/new" replace />
}

function RequirePlayers({ children }: { children: React.ReactNode }) {
  const locked = useStore((s) => s.session.locked)
  const players = useStore((s) => s.players)
  const required = useStore((s) => s.session.playerCount)
  if (!locked) return <Navigate to="/session/new" replace />
  // Guard against playerCount=0 (edge case) — treat as incomplete
  if (required <= 0 || players.length !== required) return <Navigate to="/session/players" replace />
  return <>{children}</>
}

function SharedViewPage() {
  const { isSharedView } = useSharedView()
  if (!isSharedView) return <Navigate to="/" replace />
  return <GeneratePage />
}

export default function App() {
  const { needRefresh: [needRefresh, setNeedRefresh], updateServiceWorker } = useRegisterSW()
  const [sharedSnapshot] = useState<SharedSnapshot | null>(() =>
    decodeSnapshot(window.location.hash)
  )

  const exitSharedView = useCallback(() => {
    window.location.href = window.location.origin + '/'
  }, [])

  const sharedViewValue = useMemo(() => ({
    snapshot: sharedSnapshot,
    isSharedView: !!sharedSnapshot,
    exitSharedView,
  }), [sharedSnapshot, exitSharedView])

  return (
    <ErrorBoundary routeName="app">
    <SharedViewContext.Provider value={sharedViewValue}>
      {needRefresh && (
        <UpdateBanner
          onReload={() => updateServiceWorker(true)}
          onDismiss={() => setNeedRefresh(false)}
        />
      )}
      <AdminProvider><BrowserRouter>
        <Routes>
          <Route element={<HomeLayout />}>
            <Route index element={<HomePage />} />
            <Route path="sessions" element={<SessionListPage />} />
            <Route path="ratings" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="ratings"><RatingsPage /></ErrorBoundary></Suspense>} />
            <Route path="ratings/:playerId" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="rating-player"><RatingPlayerPage /></ErrorBoundary></Suspense>} />
            <Route path="tournament" element={<Navigate to="/tournaments" replace />} />
            <Route path="tournaments" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="tournament-list"><TournamentListPage /></ErrorBoundary></Suspense>} />
            <Route path="tournaments/new" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="tournament-new"><NewTournamentPage /></ErrorBoundary></Suspense>} />
            <Route path="tournaments/new/:format" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="tournament-wizard"><NewTournamentWizard /></ErrorBoundary></Suspense>} />
            <Route path="tournaments/:id" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="tournament"><TournamentPage /></ErrorBoundary></Suspense>} />
            <Route path="instagram-post" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="instagram-post"><InstagramPostPage /></ErrorBoundary></Suspense>} />
            <Route path="admin">
              <Route index element={<Navigate to="/admin/sessions" replace />} />
              <Route path="sessions" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="admin-sessions"><AdminSessionsPage /></ErrorBoundary></Suspense>} />
              <Route path="players" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="admin-players"><AdminPlayersPage /></ErrorBoundary></Suspense>} />
              <Route path="ratings" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="admin-ratings"><AdminRatingsPage /></ErrorBoundary></Suspense>} />
              <Route path="tournaments" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="admin-tournaments"><AdminTournamentsPage /></ErrorBoundary></Suspense>} />
              <Route path="seasons" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="admin-seasons"><AdminSeasonsPage /></ErrorBoundary></Suspense>} />
            </Route>
          </Route>
          <Route path="scoreboard" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="scoreboard"><ScoreboardPage /></ErrorBoundary></Suspense>} />
          <Route element={<SessionLayout />}>
            <Route path="session/new" element={<SetupPage />} />
            <Route path="session/players" element={<RequireSession><PlayersPage /></RequireSession>} />
            <Route path="session/constraints" element={<RequirePlayers><ConstraintsPage /></RequirePlayers>} />
            <Route path="session/generate" element={<RequirePlayers><GeneratePage /></RequirePlayers>} />
            <Route path="view" element={<SharedViewPage />} />
          </Route>
          <Route path="s/:sessionId" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="shared-session"><SharedSessionPage /></ErrorBoundary></Suspense>} />
        </Routes>
      </BrowserRouter></AdminProvider>
    </SharedViewContext.Provider>
    </ErrorBoundary>
  )
}
