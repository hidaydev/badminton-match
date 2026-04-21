import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import Layout from './components/Layout'
import SetupPage from './pages/SetupPage'
import PlayersPage from './pages/PlayersPage'
import ConstraintsPage from './pages/ConstraintsPage'
import GeneratePage from './pages/GeneratePage'
import { useStore } from './store'

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

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route element={<Layout />}>
          <Route index element={<SetupPage />} />
          <Route path="players" element={<RequireSession><PlayersPage /></RequireSession>} />
          <Route path="constraints" element={<RequirePlayers><ConstraintsPage /></RequirePlayers>} />
          <Route path="generate" element={<RequirePlayers><GeneratePage /></RequirePlayers>} />
        </Route>
      </Routes>
    </BrowserRouter>
  )
}
