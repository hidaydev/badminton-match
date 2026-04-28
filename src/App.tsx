import { createContext, useContext, useState, useCallback, useMemo } from 'react'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import Layout from './components/Layout'
import SetupPage from './pages/SetupPage'
import PlayersPage from './pages/PlayersPage'
import ConstraintsPage from './pages/ConstraintsPage'
import GeneratePage from './pages/GeneratePage'
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
  return locked ? <>{children}</> : <Navigate to="/" replace />
}

function RequirePlayers({ children }: { children: React.ReactNode }) {
  const locked = useStore((s) => s.session.locked)
  const players = useStore((s) => s.players)
  const required = useStore((s) => s.session.playerCount)
  if (!locked) return <Navigate to="/" replace />
  if (players.length !== required) return <Navigate to="/players" replace />
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
          <Route element={<Layout />}>
            <Route index element={<SetupPage />} />
            <Route path="players" element={<RequireSession><PlayersPage /></RequireSession>} />
            <Route path="constraints" element={<RequirePlayers><ConstraintsPage /></RequirePlayers>} />
            <Route path="generate" element={<RequirePlayers><GeneratePage /></RequirePlayers>} />
            <Route path="view" element={<SharedViewPage />} />
          </Route>
        </Routes>
      </BrowserRouter>
    </SharedViewContext.Provider>
  )
}
