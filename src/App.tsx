import { useState, useCallback, useMemo, lazy, Suspense } from 'react'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { useRegisterSW } from 'virtual:pwa-register/react'
import UpdateBanner from './components/UpdateBanner'
import HomeLayout from './components/HomeLayout'
import SessionLayout from './components/SessionLayout'
import HomePage from './pages/HomePage'
import SetupPage from './pages/SetupPage'
import PlayersPage from './pages/PlayersPage'
import ConstraintsPage from './pages/ConstraintsPage'
import GeneratePage from './pages/GeneratePage'
import SessionListPage from './pages/SessionListPage'
import PlayerHistoryPage from './pages/PlayerHistoryPage'
import PlayerDetailPage from './pages/PlayerDetailPage'
import { useStore } from './store'
import { decodeSnapshot, type SharedSnapshot } from './utils/shareUrl'
import { SharedViewContext, useSharedView } from './sharedView'

// Lazy-loaded heavy pages (code-split)
const ScoreboardPage = lazy(() => import('./pages/ScoreboardPage'))
const InstagramPostPage = lazy(() => import('./pages/InstagramPostPage'))
const TournamentPage = lazy(() => import('./pages/TournamentPage'))
const TournamentListPage = lazy(() => import('./pages/TournamentListPage'))
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
  if (players.length !== required) return <Navigate to="/session/players" replace />
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
    <SharedViewContext.Provider value={sharedViewValue}>
      {needRefresh && (
        <UpdateBanner
          onReload={() => updateServiceWorker(true)}
          onDismiss={() => setNeedRefresh(false)}
        />
      )}
      <BrowserRouter>
        <Routes>
          <Route element={<HomeLayout />}>
            <Route index element={<HomePage />} />
            <Route path="sessions" element={<SessionListPage />} />
            <Route path="player-history" element={<PlayerHistoryPage />} />
            <Route path="player-history/:name" element={<PlayerDetailPage />} />
            <Route path="tournament" element={<Navigate to="/tournaments" replace />} />
            <Route path="tournaments" element={<Suspense fallback={<Loading />}><TournamentListPage /></Suspense>} />
            <Route path="tournaments/:id" element={<Suspense fallback={<Loading />}><TournamentPage /></Suspense>} />
            <Route path="instagram-post" element={<Suspense fallback={<Loading />}><InstagramPostPage /></Suspense>} />
          </Route>
          <Route path="scoreboard" element={<Suspense fallback={<Loading />}><ScoreboardPage /></Suspense>} />
          <Route element={<SessionLayout />}>
            <Route path="session/new" element={<SetupPage />} />
            <Route path="session/players" element={<RequireSession><PlayersPage /></RequireSession>} />
            <Route path="session/constraints" element={<RequirePlayers><ConstraintsPage /></RequirePlayers>} />
            <Route path="session/generate" element={<RequirePlayers><GeneratePage /></RequirePlayers>} />
            <Route path="view" element={<SharedViewPage />} />
          </Route>
          <Route path="s/:sessionId" element={<Suspense fallback={<Loading />}><SharedSessionPage /></Suspense>} />
        </Routes>
      </BrowserRouter>
    </SharedViewContext.Provider>
  )
}
