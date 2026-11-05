import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { AuthProvider } from './auth/AuthProvider'
import { useAuth } from './auth/AuthContext'
import ClientOutdatedBanner from './components/ClientOutdatedBanner'
import HomeLayout from './components/HomeLayout'
import SessionLayout from './components/SessionLayout'
import { CommunityProvider } from './community/CommunityProvider'
import { useCommunity } from './community/CommunityContext'
import { t } from './i18n'
import ExportPage from './pages/ExportPage'
import HomePage from './pages/HomePage'
import LoginPage from './pages/LoginPage'
import PlayerDetailPage from './pages/PlayerDetailPage'
import PlayersPage from './pages/PlayersPage'
import RankingsPage from './pages/RankingsPage'
import RatingPlayerPage from './pages/RatingPlayerPage'
import SessionPage from './pages/SessionPage'
import SessionsPage from './pages/SessionsPage'
import SettingsPage from './pages/SettingsPage'
import OwnerSetupPage from './pages/SetupPage'
import SharedSessionPage from './pages/SharedSessionPage'
import TournamentClassicPage from './pages/TournamentClassicPage'
import TournamentTeamPage from './pages/TournamentTeamPage'
import TournamentsPage from './pages/TournamentsPage'
import ConstraintsPage from './wizard/pages/ConstraintsPage'
import GeneratePage from './wizard/pages/GeneratePage'
import PlayersWizardPage from './wizard/pages/PlayersPage'
import SetupPage from './wizard/pages/SetupPage'

function Loading() {
  return (
    <div className="min-h-screen bg-ground text-fg flex items-center justify-center">
      <span className="text-sm text-fg-dim">{t('app.loading')}</span>
    </div>
  )
}

function RootRedirect() {
  const { current } = useCommunity()
  if (current !== null) {
    return <Navigate to={`/c/${encodeURIComponent(current.slug)}`} replace />
  }
  return (
    <section className="mx-auto max-w-2xl p-4">
      <h1 className="text-xl sm:text-2xl font-bold text-fg">{t('home.empty')}</h1>
      <p className="mt-2 text-sm text-fg-dim">{t('home.emptyHint')}</p>
    </section>
  )
}

function OwnerOnly({ children }: { children: React.ReactNode }) {
  const { user } = useAuth()
  if (user?.platformOwner !== true) return <Navigate to="/" replace />
  return children
}

function Protected({ children }: { children: React.ReactNode }) {
  const { user, loading } = useAuth()
  if (loading) return <Loading />
  if (!user) return <LoginPage />
  return children
}

function AuthedRoutes() {
  return (
    <Routes>
      <Route path="/" element={<RootRedirect />} />
      <Route
        path="/owner/communities"
        element={
          <OwnerOnly>
            <OwnerSetupPage />
          </OwnerOnly>
        }
      />

      <Route path="/c/:slug" element={<HomeLayout />}>
        <Route index element={<HomePage />} />
        <Route path="sessions" element={<SessionsPage />} />
        <Route path="sessions/:id" element={<SessionPage />} />
        <Route path="players" element={<PlayersPage />} />
        <Route path="players/:playerId" element={<PlayerDetailPage />} />
        <Route path="rankings" element={<RankingsPage />} />
        <Route path="rankings/:playerId" element={<RatingPlayerPage />} />
        <Route path="tournaments" element={<TournamentsPage />} />
        <Route path="tournaments/classic/new" element={<TournamentClassicPage />} />
        <Route path="tournaments/classic/:id" element={<TournamentClassicPage />} />
        <Route path="tournaments/team/new" element={<TournamentTeamPage />} />
        <Route path="tournaments/team/:id" element={<TournamentTeamPage />} />
        <Route path="export" element={<ExportPage />} />
        <Route path="settings" element={<SettingsPage />} />
      </Route>

      <Route path="/c/:slug/session" element={<SessionLayout />}>
        <Route index element={<Navigate to="new" replace />} />
        <Route path="new" element={<SetupPage />} />
        <Route path="players" element={<PlayersWizardPage />} />
        <Route path="constraints" element={<ConstraintsPage />} />
        <Route path="generate" element={<GeneratePage />} />
      </Route>

      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  )
}

export default function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <CommunityProvider>
          <ClientOutdatedBanner />
          <Routes>
            <Route path="/s/:code" element={<SharedSessionPage />} />
            <Route
              path="*"
              element={
                <Protected>
                  <AuthedRoutes />
                </Protected>
              }
            />
          </Routes>
        </CommunityProvider>
      </BrowserRouter>
    </AuthProvider>
  )
}
