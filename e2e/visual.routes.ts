/** Data the global setup creates; specs read it through `state()`. */
export type E2eState = {
  communitySlug: string
  tournamentId: string
  sessionId: string
  playerId: string
  /** A live share link for the pinned session; read-only in every spec. */
  shareCode: string
  /** One writable session per project: the specs mutate it, so they must not share. */
  writableByProject: Record<string, string>
}

/**
 * The screens in the visual and a11y baseline, written out instead of inferred
 * from the router: a page added tomorrow does not silently join the baseline,
 * and a page removed here is a review decision, not an accident.
 */
export type VisualRoute = {
  name: string
  path: (state: E2eState) => string
}

export const visualRoutes: readonly VisualRoute[] = [
  { name: 'home', path: () => '/' },
  { name: 'community', path: (state) => `/c/${state.communitySlug}` },
  { name: 'rankings', path: (state) => `/c/${state.communitySlug}/rankings` },
  { name: 'tournaments', path: (state) => `/c/${state.communitySlug}/tournaments` },
  // `App.tsx` routes `tournaments/:id`; the format is read from the record, so
  // there is no format segment in the URL.
  {
    name: 'tournament-classic',
    path: (state) => `/c/${state.communitySlug}/tournaments/${state.tournamentId}`,
  },
  { name: 'sessions', path: (state) => `/c/${state.communitySlug}/sessions` },
  // Filtered on purpose: the roster order is the server's to change, and a
  // baseline cannot pin a list whose order the API never promised.
  { name: 'players', path: (state) => `/c/${state.communitySlug}/players?q=Ani` },
  {
    name: 'player',
    path: (state) => `/c/${state.communitySlug}/players/${state.playerId}`,
  },
  {
    name: 'session',
    path: (state) => `/c/${state.communitySlug}/sessions/${state.sessionId}`,
  },
  { name: 'export', path: (state) => `/c/${state.communitySlug}/export` },
  { name: 'settings', path: (state) => `/c/${state.communitySlug}/settings` },
  { name: 'setup', path: () => '/owner/communities' },
]

/**
 * Routes the a11y baseline walks. They are the visual routes plus screens that
 * have no screenshot yet: the share page is served from the fixture's code and
 * needs no login, but its visual baseline has to be recorded on each platform
 * before it can be compared (see `__screenshots__/`).
 */
export const a11yRoutes: readonly VisualRoute[] = [
  ...visualRoutes,
  { name: 'shared', path: (state) => `/s/${state.shareCode}` },
]
