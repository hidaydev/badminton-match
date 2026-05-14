import { createContext, useContext, useState, useCallback, useMemo } from 'react'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import HomeLayout from './components/HomeLayout'
import SessionLayout from './components/SessionLayout'
import HomePage from './pages/HomePage'
import SetupPage from './pages/SetupPage'
import PlayersPage from './pages/PlayersPage'
import ConstraintsPage from './pages/ConstraintsPage'
import GeneratePage from './pages/GeneratePage'
import SharedSessionPage from './pages/SharedSessionPage'
import SessionListPage from './pages/SessionListPage'
import PlayerHistoryPage from './pages/PlayerHistoryPage'
import PlayerDetailPage from './pages/PlayerDetailPage'
import TournamentPage from './pages/TournamentPage'
import InstagramPostPage from './pages/InstagramPostPage'
import { useStore } from './store'
import { decodeSnapshot, type SharedSnapshot } from './utils/shareUrl'

interface SharedViewContextType {
  snapshot: SharedSnapshot | null
  isSharedView: boolean
  exitSharedView: () => void
}

const SharedViewContext = createContext<SharedViewContextType>({
  snapshot: null,
  isSharedView: false,
  exitSharedView: () => {},
})

export function useSharedView() {
  return useContext(SharedViewContext)
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
  const [sharedSnapshot] = useState<SharedSnapshot | null>(() =>
    decodeSnapshot(window.location.hash)
  )

  const exitSharedView = useCallback(() => {
    window.location.href = window.location.origin + '/'
  }, [])

  const sharedViewValue = useMemo<SharedViewContextType>(() => ({
    snapshot: sharedSnapshot,
    isSharedView: !!sharedSnapshot,
    exitSharedView,
  }), [sharedSnapshot, exitSharedView])

  return (
    <SharedViewContext.Provider value={sharedViewValue}>
      <BrowserRouter>
        <Routes>
          <Route element={<HomeLayout />}>
            <Route index element={<HomePage />} />
            <Route path="sessions" element={<SessionListPage />} />
            <Route path="player-history" element={<PlayerHistoryPage />} />
            <Route path="player-history/:name" element={<PlayerDetailPage />} />
            <Route path="tournament" element={<TournamentPage />} />
            <Route path="instagram-post" element={<InstagramPostPage />} />
          </Route>
          <Route element={<SessionLayout />}>
            <Route path="session/new" element={<SetupPage />} />
            <Route path="session/players" element={<RequireSession><PlayersPage /></RequireSession>} />
            <Route path="session/constraints" element={<RequirePlayers><ConstraintsPage /></RequirePlayers>} />
            <Route path="session/generate" element={<RequirePlayers><GeneratePage /></RequirePlayers>} />
            <Route path="view" element={<SharedViewPage />} />
          </Route>
          <Route path="s/:sessionId" element={<SharedSessionPage />} />
        </Routes>
      </BrowserRouter>
    </SharedViewContext.Provider>
  )
}
