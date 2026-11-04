import { createElement } from 'react'
import type { ReactElement } from 'react'
import type { CommunityRole } from './auth/api'
import type { MessageKey } from './i18n/en'
import CommunityPage from './pages/CommunityPage'
import HomePage from './pages/HomePage'
import PlaceholderPage from './pages/PlaceholderPage'
import RankingsPage from './pages/RankingsPage'
import RatingPlayerPage from './pages/RatingPlayerPage'
import TournamentClassicPage from './pages/TournamentClassicPage'
import TournamentTeamPage from './pages/TournamentTeamPage'
import TournamentsPage from './pages/TournamentsPage'

export type NavGroup = 'main' | 'admin' | 'owner'

export type RouteEntry = {
  /** React Router path. `:slug` marks a community-scoped screen. */
  path: string
  labelKey: MessageKey
  element: ReactElement
  requiresAuth: boolean
  /** Community roles allowed to see the entry. Omitted = every member. */
  roles?: readonly CommunityRole[]
  /** Only the platform owner sees this entry. */
  platformOwner?: boolean
  /** Nav section; entries without a group are routed but never listed. */
  navGroup?: NavGroup
}

const ALL_ROLES = ['admin', 'host', 'member'] as const
const STAFF_ROLES = ['admin', 'host'] as const

function placeholder(labelKey: MessageKey): ReactElement {
  return createElement(PlaceholderPage, { labelKey })
}

/**
 * Single source of truth for the shell. Later tasks replace a placeholder
 * element with a real page; `App.tsx` does not change.
 */
export const routes: readonly RouteEntry[] = [
  {
    path: '/',
    labelKey: 'nav.home',
    element: createElement(HomePage),
    requiresAuth: true,
    navGroup: 'main',
  },
  {
    path: '/c/:slug',
    labelKey: 'nav.overview',
    element: createElement(CommunityPage),
    requiresAuth: true,
    roles: ALL_ROLES,
  },
  {
    path: '/c/:slug/sessions',
    labelKey: 'nav.sessions',
    element: placeholder('nav.sessions'),
    requiresAuth: true,
    roles: ALL_ROLES,
    navGroup: 'main',
  },
  {
    path: '/c/:slug/players',
    labelKey: 'nav.players',
    element: placeholder('nav.players'),
    requiresAuth: true,
    roles: ALL_ROLES,
    navGroup: 'main',
  },
  {
    path: '/c/:slug/rankings',
    labelKey: 'nav.rankings',
    element: createElement(RankingsPage),
    requiresAuth: true,
    roles: ALL_ROLES,
    navGroup: 'main',
  },
  {
    path: '/c/:slug/rankings/:playerId',
    labelKey: 'player.title',
    element: createElement(RatingPlayerPage),
    requiresAuth: true,
    roles: ALL_ROLES,
  },
  {
    path: '/c/:slug/tournaments',
    labelKey: 'nav.tournaments',
    element: createElement(TournamentsPage),
    requiresAuth: true,
    roles: STAFF_ROLES,
    navGroup: 'main',
  },
  {
    path: '/c/:slug/tournaments/classic/new',
    labelKey: 'tournaments.newClassic',
    element: createElement(TournamentClassicPage),
    requiresAuth: true,
    roles: STAFF_ROLES,
  },
  {
    path: '/c/:slug/tournaments/classic/:id',
    labelKey: 'tournaments.title',
    element: createElement(TournamentClassicPage),
    requiresAuth: true,
    roles: STAFF_ROLES,
  },
  {
    path: '/c/:slug/tournaments/team/new',
    labelKey: 'tournaments.newTeam',
    element: createElement(TournamentTeamPage),
    requiresAuth: true,
    roles: STAFF_ROLES,
  },
  {
    path: '/c/:slug/tournaments/team/:id',
    labelKey: 'tournaments.title',
    element: createElement(TournamentTeamPage),
    requiresAuth: true,
    roles: STAFF_ROLES,
  },
  {
    path: '/c/:slug/settings',
    labelKey: 'nav.settings',
    element: placeholder('nav.settings'),
    requiresAuth: true,
    roles: ['admin'],
    navGroup: 'admin',
  },
  {
    path: '/s/:code',
    labelKey: 'shared.title',
    element: placeholder('shared.title'),
    requiresAuth: false,
  },
  {
    path: '/owner/communities',
    labelKey: 'nav.owner',
    element: placeholder('nav.owner'),
    requiresAuth: true,
    platformOwner: true,
    navGroup: 'owner',
  },
]

export type NavEntry = {
  path: string
  labelKey: MessageKey
  group: NavGroup
}

/** `role` is the role in the selected community; `null` when none is selected. */
export function visibleNav(
  role: CommunityRole | null,
  platformOwner: boolean,
  entries: readonly RouteEntry[] = routes,
): NavEntry[] {
  return entries.flatMap((entry) => {
    if (entry.navGroup === undefined || !entry.requiresAuth) return []
    if (entry.platformOwner) return platformOwner ? [toNav(entry)] : []
    if (!entry.path.includes(':slug')) return [toNav(entry)]
    if (role === null) return []
    if (entry.roles && !entry.roles.includes(role)) return []
    return [toNav(entry)]
  })
}

function toNav(entry: RouteEntry): NavEntry {
  return {
    path: entry.path,
    labelKey: entry.labelKey,
    group: entry.navGroup as NavGroup,
  }
}

/** `/c/acme/sessions` -> `acme`; `null` outside a community path. */
export function communitySlugFromPath(pathname: string): string | null {
  const match = /^\/c\/([^/]+)/.exec(pathname)
  return match ? decodeURIComponent(match[1]) : null
}
