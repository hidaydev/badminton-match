/** Data the global setup creates; specs read it through `state()`. */
export type E2eState = {
  communitySlug: string
  tournamentId: string
  sessionId: string
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
  {
    name: 'tournament-classic',
    path: (state) => `/c/${state.communitySlug}/tournaments/classic/${state.tournamentId}`,
  },
  { name: 'sessions', path: (state) => `/c/${state.communitySlug}/sessions` },
  {
    name: 'session',
    path: (state) => `/c/${state.communitySlug}/sessions/${state.sessionId}`,
  },
  { name: 'export', path: (state) => `/c/${state.communitySlug}/export` },
]
