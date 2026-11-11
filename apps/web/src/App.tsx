import { Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { QueryClient, QueryClientProvider, useQueryClient } from '@tanstack/react-query'
import { BrowserRouter, Navigate, Route, Routes, useParams } from 'react-router-dom'
import { QUERY_RETRY_COUNT, QUERY_STALE_MS } from './api/retryPolicy'
import { settled } from './api/settled'
import { AuthProvider } from './auth/AuthProvider'
import { useAuth } from './auth/AuthContext'
import { Button } from './components/Button'
import { ClientOutdatedBanner } from './components/ClientOutdatedBanner'
import { LoadingState } from './components/LoadingState'
import { PageHeader } from './components/PageHeader'
import { RouteChange } from './components/RouteChange'
import { CommunityProvider } from './community/CommunityProvider'
import { DirectoryList } from './community/DirectoryList'
import { JoinRequestCard } from './community/JoinRequestCard'
import { useCommunity } from './community/CommunityContext'
import { t } from './i18n'
import InvitePage from './pages/InvitePage'
import LoginPage from './pages/LoginPage'
import NotFoundPage from './pages/NotFoundPage'
import PlayerDetailPage from './pages/PlayerDetailPage'
import PlayersPage from './pages/PlayersPage'
import PrivacyPage from './pages/PrivacyPage'
import TermsPage from './pages/TermsPage'
import SettingsPage from './pages/SettingsPage'
import OwnerSetupPage from './pages/SetupPage'
import SharedSessionPage from './pages/SharedSessionPage'
import { useRegisterSW } from 'virtual:pwa-register/react'
import { installUpdateOnVisible } from './pwa/updateCheck'
// Restored v1 tree. Everything under `legacy/` is the pre-rewrite frontend,
// rewired through `legacy/router` and `legacy/queries/endpoints`.
import { AdminProvider, useAdmin } from './legacy/context/AdminContext'
import HomeLayout from './legacy/components/HomeLayout'
import SessionLayout from './legacy/components/SessionLayout'
import GlobalAmbiguousNames from './legacy/context/GlobalAmbiguousNames'
import UpdateBanner from './legacy/components/UpdateBanner'
import ErrorBoundary from './legacy/components/ErrorBoundary'
import { ButtonLink } from './components/Button'
import { EmptyState } from './components/EmptyState'
import HomePage from './legacy/pages/HomePage'
import SetupPage from './legacy/pages/SetupPage'
import PlayersWizardPage from './legacy/pages/PlayersPage'
import SessionListPage from './legacy/pages/SessionListPage'
import { LegacySlugProvider, Navigate as LegacyNavigate, Outlet as LegacyOutlet } from './legacy/router'
import { setCommunitySlug } from './legacy/queries/endpoints'
import { useStore, prepareCommunityDraft } from './legacy/store'
import { decodeSnapshot, type SharedSnapshot } from './legacy/utils/shareUrl'
import { SharedViewContext, useSharedView } from './legacy/sharedView'
import { safeLazy } from './legacy/utils/safeLazy'

const ScoreboardPage = safeLazy(() => import('./legacy/pages/ScoreboardPage'))
const InstagramPostPage = safeLazy(() => import('./legacy/pages/InstagramPostPage'))
// The wizard's last two steps pull in the summary modal (and dnd-kit), so they
// load when the step is entered instead of with the first byte of the app.
const ConstraintsPage = safeLazy(() => import('./legacy/pages/ConstraintsPage'))
const GeneratePage = safeLazy(() => import('./legacy/pages/GeneratePage'))
// The dev preview mounts the summary grid, which is the only other entry point
// to dnd-kit; keeping it lazy keeps the drag library out of the first load.
const SharedSessionPreviewPage = safeLazy(() => import('./legacy/pages/SessionPreviewPage'))
const TournamentRouter = safeLazy(() => import('./legacy/pages/TournamentRouter'))
const TournamentListPage = safeLazy(() => import('./legacy/pages/TournamentListPage'))
const RankingsPage = safeLazy(() => import('./legacy/pages/RankingsPage'))
const AdminSessionsPage = safeLazy(() => import('./legacy/pages/admin/AdminSessionsPage'))
const AdminRatingsPage = safeLazy(() => import('./legacy/pages/admin/AdminRatingsPage'))
const AdminTournamentsPage = safeLazy(() => import('./legacy/pages/admin/AdminTournamentsPage'))
const RatingPlayerPage = safeLazy(() => import('./legacy/pages/RatingPlayerPage'))
const AchievementBadgesPreviewPage = safeLazy(() => import('./legacy/pages/AchievementBadgesPreviewPage'))
const MatchResultPreview = safeLazy(() => import('./legacy/pages/MatchResultPreview'))
const NewTournamentPage = safeLazy(() => import('./legacy/pages/NewTournamentPage'))
const NewTournamentWizard = safeLazy(() => import('./legacy/pages/NewTournamentWizard'))
const LegacySharedSessionPage = safeLazy(() => import('./legacy/pages/SharedSessionPage'))

// Mock-only preview screens. They are useful while developing the summary grid
// and medal badges, but a production build must not serve them.
const DEV_PREVIEWS = import.meta.env.DEV

// The restored v1 screens use TanStack Query and so do the v2 player reads, so
// one provider at the root serves both. Every policy a query can inherit is
// declared here and nowhere else: a hook that set its own retry or stale window
// would make that screen disagree with the rest of the app.
//
// Exported so a test can start from an empty cache: one client serves the whole
// app, and an answer left behind by one case would be handed to the next.
// eslint-disable-next-line react-refresh/only-export-components
export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: QUERY_RETRY_COUNT,
      staleTime: QUERY_STALE_MS,
      refetchOnWindowFocus: false,
    },
  },
})

function Loading() {
  return (
    <div className="min-h-screen bg-ground text-fg flex items-center justify-center p-4">
      <div className="w-full max-w-3xl">
        <LoadingState label={t('app.loading')} />
      </div>
    </div>
  )
}

function RequireSession({ children }: { children: React.ReactNode }) {
  const locked = useStore((s) => s.session.locked)
  return locked ? <>{children}</> : <LegacyNavigate to="/session/new" replace />
}

function RequireStaff({ children }: { children: React.ReactNode }) {
  const { isAdmin } = useAdmin()
  return isAdmin ? <>{children}</> : <LegacyNavigate to="/" replace />
}

function RequireAdmin({ children }: { children: React.ReactNode }) {
  const { isAdminRole } = useAdmin()
  return isAdminRole ? <>{children}</> : <LegacyNavigate to="/" replace />
}

function RequirePlayers({ children }: { children: React.ReactNode }) {
  const locked = useStore((s) => s.session.locked)
  const players = useStore((s) => s.players)
  const required = useStore((s) => s.session.playerCount)
  if (!locked) return <LegacyNavigate to="/session/new" replace />
  if (required <= 0 || players.length !== required) return <LegacyNavigate to="/session/players" replace />
  return <>{children}</>
}

function SharedViewPage() {
  const { isSharedView } = useSharedView()
  if (!isSharedView) return <LegacyNavigate to="/" replace />
  return (
    <Suspense fallback={<Loading />}>
      <GeneratePage />
    </Suspense>
  )
}

/**
 * Every legacy route lives under `/c/:slug`. This shell publishes the slug to
 * the data adapter and to the path-prefixing router, then renders the same
 * layout tree the pre-rewrite app had.
 */
function LegacyShell() {
  const { slug = '' } = useParams<{ slug: string }>()
  const { memberships } = useCommunity()
  const queryClient = useQueryClient()
  const previousSlug = useRef(slug)
  // A slug outside the account's memberships is a link to someone else's
  // community, not a preference to fall back from. Rendering the usual tree
  // would query that slug (the adapter reads the URL) with this account's role.
  const isMember = memberships.some((membership) => membership.slug === slug)

  // A community switch must not reuse the previous slug's cache or draft.
  // `prepareCommunityDraft` only applies a persisted draft tagged with `slug`.
  // Publishing the slug from an effect (not from the render body) keeps a
  // discarded concurrent render from changing the module state; the data
  // adapter reads the slug from the URL itself.
  useEffect(() => {
    if (!isMember) return
    setCommunitySlug(slug)
    if (previousSlug.current !== slug) {
      queryClient.removeQueries({ queryKey: [previousSlug.current] })
      previousSlug.current = slug
    }
    prepareCommunityDraft(slug)
  }, [slug, isMember, queryClient])

  if (!isMember) return <CommunityNotFound />

  return (
    <LegacySlugProvider key={slug} slug={slug}>
      <AdminProvider>
        <GlobalAmbiguousNames>
          <LegacyOutlet />
        </GlobalAmbiguousNames>
      </AdminProvider>
    </LegacySlugProvider>
  )
}

function LegacySessionRedirect() {
  const { id = '' } = useParams<{ id: string }>()
  return <LegacyNavigate to={`/s/${id}`} replace />
}

function CommunityNotFound() {
  return (
    <section className="mx-auto w-full max-w-3xl px-4 py-4">
      <PageHeader title={t('community.error.notFound')} />
      <ButtonLink to="/" variant="secondary" className="mt-4 inline-flex items-center">
        {t('nav.home')}
      </ButtonLink>
    </section>
  )
}

/**
 * This screen is the only signed-in page outside the community shell, so the
 * account menu in `HomeLayout` never renders here. Without this row an account
 * with no membership has nowhere to sign out.
 */
function AccountRow() {
  const { user, logout } = useAuth()
  const [signingOut, setSigningOut] = useState(false)

  const signOut = async () => {
    setSigningOut(true)
    try {
      await logout()
    } catch {
      // The row stays on screen, so a second tap retries the same request.
    } finally {
      setSigningOut(false)
    }
  }

  return (
    <div className="flex min-h-11 items-center justify-between gap-3">
      <p className="min-w-0 truncate text-sm text-fg-dim">
        {t('nav.signedInAs', { name: user?.displayName ?? '' })}
      </p>
      <Button
        variant="secondary"
        className="shrink-0"
        onClick={() => signOut()}
        disabled={signingOut}
      >
        {t('nav.logout')}
      </Button>
    </div>
  )
}

function RootRedirect() {
  const { current } = useCommunity()
  const { user } = useAuth()
  const [joinSlug, setJoinSlug] = useState('')
  if (current !== null) {
    return <Navigate to={`/c/${encodeURIComponent(current.slug)}`} replace />
  }
  // The empty state must offer what this account can actually do: only the
  // platform owner can create a community, everyone else asks to join one.
  const isOwner = user?.platformOwner === true
  return (
    <section className="mx-auto w-full max-w-3xl px-4 pb-[calc(1rem+env(safe-area-inset-bottom))] pt-[calc(1rem+env(safe-area-inset-top))]">
      <AccountRow />
      <EmptyState
        as="h1"
        className="mt-6"
        titleClassName="text-xl sm:text-2xl font-bold"
        title={t('home.empty')}
        description={isOwner ? t('home.emptyOwnerHint') : t('home.emptyHint')}
        action={
          isOwner ? (
            <ButtonLink to="/owner/communities" className="inline-flex items-center">
              {t('home.createCommunity')}
            </ButtonLink>
          ) : undefined
        }
      />
      {!isOwner && (
        <>
          <DirectoryList onPick={setJoinSlug} />
          <JoinRequestCard slug={joinSlug} onSlugChange={setJoinSlug} />
        </>
      )}
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

      <Route path="/c/:slug" element={<LegacyShell />}>
        <Route element={<HomeLayout />}>
          <Route index element={<HomePage />} />
          <Route path="sessions" element={<SessionListPage />} />
          <Route path="sessions/:id" element={<LegacySessionRedirect />} />
          <Route path="rankings" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="rankings"><RankingsPage /></ErrorBoundary></Suspense>} />
          <Route path="rankings/:playerId" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="rankings-player"><RatingPlayerPage /></ErrorBoundary></Suspense>} />
          <Route path="ratings" element={<LegacyNavigate to="/rankings" replace />} />
          <Route path="ratings/:playerId" element={<LegacyNavigate to="/rankings" replace />} />
          {DEV_PREVIEWS && (
            <>
              <Route path="dev/achievement-badges" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="achievement-badges-preview"><AchievementBadgesPreviewPage /></ErrorBoundary></Suspense>} />
              <Route path="dev/match-result-preview" element={<Suspense fallback={<Loading />}><MatchResultPreview /></Suspense>} />
              <Route path="dev/session-preview" element={<Suspense fallback={<Loading />}><SharedSessionPreviewPage /></Suspense>} />
            </>
          )}
          <Route path="tournament" element={<LegacyNavigate to="/tournaments" replace />} />
          <Route path="tournaments" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="tournament-list"><TournamentListPage /></ErrorBoundary></Suspense>} />
          <Route path="tournaments/new" element={<RequireStaff><Suspense fallback={<Loading />}><ErrorBoundary routeName="tournament-new"><NewTournamentPage /></ErrorBoundary></Suspense></RequireStaff>} />
          <Route path="tournaments/new/:format" element={<RequireStaff><Suspense fallback={<Loading />}><ErrorBoundary routeName="tournament-wizard"><NewTournamentWizard /></ErrorBoundary></Suspense></RequireStaff>} />
          <Route path="tournaments/:id" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="tournament"><TournamentRouter /></ErrorBoundary></Suspense>} />
          <Route path="instagram-post" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="instagram-post"><InstagramPostPage /></ErrorBoundary></Suspense>} />

          {/* v2-only screens: settings and player claims did not exist before. */}
          <Route path="settings" element={<RequireAdmin><SettingsPage /></RequireAdmin>} />
          <Route path="players" element={<PlayersPage />} />
          <Route path="players/:playerId" element={<PlayerDetailPage />} />
          {/* The old export screen is gone; its URL now points at the post editor. */}
          <Route path="export" element={<LegacyNavigate to="/instagram-post" replace />} />

          <Route path="admin">
            <Route index element={<LegacyNavigate to="/admin/sessions" replace />} />
            <Route path="sessions" element={<RequireStaff><Suspense fallback={<Loading />}><ErrorBoundary routeName="admin-sessions"><AdminSessionsPage /></ErrorBoundary></Suspense></RequireStaff>} />
            <Route path="players" element={<LegacyNavigate to="/players" replace />} />
            <Route path="ratings" element={<RequireAdmin><Suspense fallback={<Loading />}><ErrorBoundary routeName="admin-ratings"><AdminRatingsPage /></ErrorBoundary></Suspense></RequireAdmin>} />
            <Route path="tournaments" element={<RequireStaff><Suspense fallback={<Loading />}><ErrorBoundary routeName="admin-tournaments"><AdminTournamentsPage /></ErrorBoundary></Suspense></RequireStaff>} />
          </Route>
        </Route>

        <Route element={<SessionLayout />}>
          <Route path="session/new" element={<RequireStaff><SetupPage /></RequireStaff>} />
          <Route path="session/players" element={<RequireStaff><RequireSession><PlayersWizardPage /></RequireSession></RequireStaff>} />
          <Route path="session/constraints" element={<RequireStaff><RequirePlayers><Suspense fallback={<Loading />}><ConstraintsPage /></Suspense></RequirePlayers></RequireStaff>} />
          <Route path="session/generate" element={<RequireStaff><RequirePlayers><Suspense fallback={<Loading />}><GeneratePage /></Suspense></RequirePlayers></RequireStaff>} />
          <Route path="view" element={<SharedViewPage />} />
        </Route>

        <Route path="s/:sessionId" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="shared-session"><LegacySharedSessionPage /></ErrorBoundary></Suspense>} />
        <Route path="scoreboard" element={<Suspense fallback={<Loading />}><ErrorBoundary routeName="scoreboard"><ScoreboardPage /></ErrorBoundary></Suspense>} />

        {/* A path inside the community that no screen owns. It stays under
            `/c/:slug` so the slug is still available to link back to. */}
        <Route path="*" element={<NotFoundPage />} />
      </Route>

      <Route path="*" element={<NotFoundPage />} />
    </Routes>
  )
}

export default function App() {
  const { needRefresh: [needRefresh, setNeedRefresh], updateServiceWorker } = useRegisterSW({
    onRegisteredSW(_swUrl, registration) {
      if (registration) installUpdateOnVisible(registration)
    },
  })
  const [sharedSnapshot] = useState<SharedSnapshot | null>(() =>
    decodeSnapshot(window.location.hash),
  )

  const exitSharedView = useCallback(() => {
    window.location.href = `${window.location.origin}/`
  }, [])

  const sharedViewValue = useMemo(
    () => ({
      snapshot: sharedSnapshot,
      isSharedView: !!sharedSnapshot,
      exitSharedView,
    }),
    [sharedSnapshot, exitSharedView],
  )

  return (
    <QueryClientProvider client={queryClient}>
    <ErrorBoundary routeName="app">
      <SharedViewContext.Provider value={sharedViewValue}>
        {needRefresh && (
          <UpdateBanner
            onReload={() => settled(updateServiceWorker(true), 'service worker update failed')}
            onDismiss={() => setNeedRefresh(false)}
          />
        )}
        <AuthProvider>
          <BrowserRouter>
            <CommunityProvider>
              <ClientOutdatedBanner
                message={t('app.outdated')}
                actionLabel={t('app.outdated.action')}
              />
              <RouteChange />
              <Routes>
                <Route path="/s/:code" element={<SharedSessionPage />} />
                {/* Accepting is how an account gets its first membership, so
                    this route cannot sit behind the community shell. */}
                <Route path="/invites/:token" element={<InvitePage />} />
                {/* Public legal pages: readable without a session and outside
                    the community shell. */}
                <Route path="/privacy" element={<PrivacyPage />} />
                <Route path="/terms" element={<TermsPage />} />
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
      </SharedViewContext.Provider>
    </ErrorBoundary>
    </QueryClientProvider>
  )
}
