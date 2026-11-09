/** Data the global setup creates; specs read it through `state()`. */
export type E2eState = {
  communitySlug: string
  /** The fixture's names, so a spec can wait for data without repeating them. */
  communityName: string
  tournamentId: string
  tournamentName: string
  sessionId: string
  sessionTitle: string
  playerId: string
  playerName: string
  /** A live share link for the pinned session; read-only in every spec. */
  shareCode: string
  /** One writable session per project: the specs mutate it, so they must not share. */
  writableByProject: Record<string, string>
  /** A second writable session per project, for the two-writer spec. */
  occByProject: Record<string, string>
  /** Writable sessions live outside the community the baselines pin. */
  writableCommunitySlug: string
  /**
   * A live member session cookie for `e2e-club` (QA-18). The OIDC stub signs in
   * one identity only, so a lower role cannot be reached through the login
   * screen; global-setup mints this row and the authz spec replays it.
   */
  memberCookie: string
}

/**
 * The screens in the visual and a11y baseline, written out instead of inferred
 * from the router: a page added tomorrow does not silently join the baseline,
 * and a page removed here is a review decision, not an accident.
 */
export type VisualRoute = {
  name: string
  path: (state: E2eState) => string
  /**
   * What proves the screen has loaded: a selector for data the screen renders.
   *
   * This replaces `page.waitForLoadState('networkidle')`, which never settles on
   * a screen that holds a WebSocket open and hides a slow read behind a 30
   * second timeout. A selector that only exists once the read has come back
   * fails in one line naming the route, instead of a screenshot of a loading
   * skeleton.
   */
  ready: (state: E2eState) => string
  /**
   * Mask the empty date filter in the screenshot. WebKit paints today's date
   * into an empty `<input type="date">` and `setFixedTime` does not reach that
   * native control, so a shot of this screen is otherwise different every day.
   */
  maskDateFilter?: boolean
  /**
   * Selectors hidden before the shot. A value that changes on every build (the
   * scoreboard's build stamp) would invalidate the baseline on every deploy.
   */
  hide?: readonly string[]
  /**
   * Set the scoreboard's "install sheet shown today" key before the first
   * paint, so the baseline pins the scoring surface instead of a first-visit
   * overlay that only some engines render.
   */
  suppressInstallSheet?: boolean
}

export const visualRoutes: readonly VisualRoute[] = [
  // `App.tsx` redirects `/` to the current community, so the home and community
  // baselines are the same screen; both are kept because the redirect is what
  // the home URL has to keep doing.
  { name: 'home', path: () => '/', ready: (state) => `text=${state.sessionTitle}` },
  {
    name: 'community',
    path: (state) => `/c/${state.communitySlug}`,
    ready: (state) => `text=${state.sessionTitle}`,
  },
  // The fixture community has no rated sessions, so the board's empty state is
  // what its own data produces.
  {
    name: 'rankings',
    path: (state) => `/c/${state.communitySlug}/rankings`,
    ready: () => 'text=No points yet',
  },
  {
    name: 'tournaments',
    path: (state) => `/c/${state.communitySlug}/tournaments`,
    ready: (state) => `text=${state.tournamentName}`,
  },
  // `App.tsx` routes `tournaments/:id`; the format is read from the record, so
  // there is no format segment in the URL.
  {
    name: 'tournament-classic',
    path: (state) => `/c/${state.communitySlug}/tournaments/${state.tournamentId}`,
    ready: (state) => `text=${state.tournamentName}`,
  },
  {
    name: 'sessions',
    path: (state) => `/c/${state.communitySlug}/sessions`,
    ready: (state) => `text=${state.sessionTitle}`,
    maskDateFilter: true,
  },
  // Filtered on purpose: the roster order is the server's to change, and a
  // baseline cannot pin a list whose order the API never promised.
  {
    name: 'players',
    path: (state) => `/c/${state.communitySlug}/players?q=Ani`,
    ready: (state) => `text=${state.playerName}`,
  },
  {
    name: 'player',
    path: (state) => `/c/${state.communitySlug}/players/${state.playerId}`,
    ready: (state) => `text=${state.playerName}`,
  },
  {
    name: 'session',
    path: (state) => `/c/${state.communitySlug}/sessions/${state.sessionId}`,
    ready: (state) => `text=${state.sessionTitle}`,
  },
  // The poster is drawn onto a canvas, so the canvas is the element that proves
  // the screen mounted; there is no text until it is rasterised.
  {
    name: 'export',
    path: (state) => `/c/${state.communitySlug}/export`,
    ready: () => 'canvas',
  },
  {
    name: 'settings',
    path: (state) => `/c/${state.communitySlug}/settings`,
    ready: (state) => `text=${state.communityName}`,
  },
  {
    name: 'setup',
    path: () => '/owner/communities',
    ready: (state) => `text=${state.communityName}`,
  },
]

/**
 * Routes the a11y baseline walks. They are the visual routes plus screens that
 * have no screenshot yet: the share page is served from the fixture's code and
 * needs no login, but its visual baseline has to be recorded on each platform
 * before it can be compared (see `__screenshots__/`).
 */
export const a11yRoutes: readonly VisualRoute[] = [
  ...visualRoutes,
  {
    name: 'shared',
    path: (state) => `/s/${state.shareCode}`,
    ready: (state) => `text=${state.sessionTitle}`,
  },
  // CMP-19: the scoreboard is a separate deployable on its own preview port, so
  // its route is an absolute URL. It needs no session, but it is the only
  // surface with coloured backgrounds, which is why it is in the a11y walk
  // already. It joins `visualRoutes` when its PNGs exist for both platforms:
  // CI only compares, so a list entry without a baseline fails every ref rather
  // than recording one. The build stamp changes on every build and the
  // first-visit install sheet covers the scoring surface, so the recorded shot
  // needs the `hide` entry and `suppressInstallSheet` already honoured by
  // `visual.spec.ts`.
  {
    name: 'scoreboard',
    path: () => process.env.E2E_SCOREBOARD_BASE_URL ?? 'http://127.0.0.1:4173/',
    ready: () => 'text=tap to score',
    hide: ['[data-testid="build-stamp"]'],
    suppressInstallSheet: true,
  },
  // Static prose the shell links from the account menu. They carry no data, so
  // the heading is the readiness signal.
  { name: 'privacy', path: () => '/privacy', ready: () => 'h1' },
  { name: 'terms', path: () => '/terms', ready: () => 'h1' },
]