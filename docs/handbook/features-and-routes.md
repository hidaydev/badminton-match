# Features And Routes

Two separate maps: **web routes** (React Router) and **API operations** (OpenAPI contract).
They differ: the page `/c/{slug}/rankings` calls `GET /c/{slug}/rankings`.

## 1. Web routes

Single source: `apps/web/src/App.tsx`. `apps/web/src/routes.manifest.ts` only
provides path helpers (`communitySlugFromPath`, `communityHref`); that file no
longer maps routes or menus.

All legacy screens live under `/c/:slug` through `LegacyShell`; the public URLs
`/s/:code` and `/invites/:token` are outside that shell.

| Path | Page | Access | Notes |
|---|---|---|---|
| `/` | `RootRedirect` | login | redirect to the active community |
| `/owner/communities` | `OwnerSetupPage` (`pages/SetupPage.tsx`) | platform owner | create community + community list |
| `/c/:slug` | legacy `HomePage` | login | hub: new session, continue session, navigation cards, admin grid |
| `/c/:slug/sessions` | legacy `SessionListPage` | login | session list |
| `/c/:slug/sessions/:id` | redirect | login | redirected to `/c/:slug/s/:id` |
| `/c/:slug/s/:sessionId` | legacy `SharedSessionPage` | login | full session page: scores, swap, absent, skip |
| `/c/:slug/scoreboard` | legacy `ScoreboardPage` | login | courtside scores |
| `/c/:slug/rankings` | legacy `RankingsPage` | login | points board + tier filter |
| `/c/:slug/rankings/:playerId` | legacy `RatingPlayerPage` | login | rating detail, history, badges |
| `/c/:slug/ratings`, `/ratings/:playerId` | redirect | login | redirected to `/rankings` |
| `/c/:slug/tournaments` | legacy `TournamentListPage` | login | classic + team list |
| `/c/:slug/tournaments/new` | legacy `NewTournamentPage` | admin/host | choose format |
| `/c/:slug/tournaments/new/:format` | legacy `NewTournamentWizard` | admin/host | classic/team wizard |
| `/c/:slug/tournaments/:id` | legacy `TournamentRouter` | login | score editor + standings/bracket |
| `/c/:slug/instagram-post` | legacy `InstagramPostPage` | admin/host | 1080×1350 post and 1080×1920 story |
| `/c/:slug/export` | redirect | admin/host | redirected to `/instagram-post` |
| `/c/:slug/settings` | `SettingsPage` | admin | members, roles, invites, join requests |
| `/c/:slug/players` | `PlayersPage` | login | v2 roster, add player, claims |
| `/c/:slug/players/:playerId` | `PlayerDetailPage` | login | detail, edit, merge, delete, claim |
| `/c/:slug/admin` | redirect | admin/host | redirected to `/admin/sessions` |
| `/c/:slug/admin/sessions` | legacy `AdminSessionsPage` | admin/host | unlock and delete sessions |
| `/c/:slug/admin/ratings` | legacy `AdminRatingsPage` | admin | rating sources, ingest, revert, rebuild |
| `/c/:slug/admin/players` | redirect | admin/host | redirected to `/players` |
| `/c/:slug/admin/tournaments` | legacy `AdminTournamentsPage` | admin/host | delete tournament |
| `/c/:slug/session/new` | legacy `SetupPage` | admin/host | session wizard: setup |
| `/c/:slug/session/players` | legacy `PlayersWizardPage` | admin/host | session wizard: players |
| `/c/:slug/session/constraints` | legacy `ConstraintsPage` | admin/host | session wizard: constraints |
| `/c/:slug/session/generate` | legacy `GeneratePage` | admin/host | session wizard: generate + publish |
| `/c/:slug/view` | `SharedViewPage` | login | open an old share snapshot (compatibility) |
| `/c/:slug/dev/achievement-badges` | preview | login | development only |
| `/c/:slug/dev/match-result-preview` | preview | login | development only |
| `/c/:slug/dev/session-preview` | preview | login | development only |
| `/invites/:token` | `InvitePage` (`pages/InvitePage.tsx`) | public | accept an invite; login with this URL as `returnTo` |
| `/s/:code` | `SharedSessionPage` | public | read-only session from a share code, Games/Standings tabs |

Notes:

- Navigation does not use a global menu. `HomeLayout` holds the community picker,
  refresh, and account menu. The account menu contains only identity + community role,
  `Community settings` (admin), `All communities` (platform owner), and
  `Sign out`; there is no Admin link in it. Screen changes go through cards
  on home.
- `HomePage` only shows the New Session CTA and the admin grid for staff
  (`isAdmin` = host or admin). The grid holds Unlock Session and Tournament for
  staff, plus Ratings and Settings for community admins only (`isAdminRole`).
- Access matrix: `member` read-only pages only; `host` adds sessions/tournaments
  (wizard, admin sessions/tournaments, post editor); `admin` adds Settings,
  Ratings, and member management. The platform owner manages communities through
  `/owner/communities`.
- v2 routes that were never mounted in the router (home, sessions, rankings,
  tournaments, export) were removed together with the canvas renderer and the v2
  tournament editor. The active tournament editor is the legacy one.
- `/c/:slug/s/:sessionId` is the editable session page and is for logged-in
  members only. `/s/:code` is the read-only public view.
- The only public link is `/s/:code`, created by the Share button; the member URL
  `/c/:slug/s/:sessionId` always asks for login and is not a link to share.
- `/s/:code` uses the in-app session screen layout: **Games** and
  **Standings** tabs. `GET /s/{code}` sends `games` and `standings` (the same tally as
  `GET /c/{slug}/sessions/{id}/standings`, without player ids).
- `/invites/:token` is deliberately outside the community shell: the account has just joined, so
  that screen must not require membership first.

## 2. Page capabilities

### Home & community

- Legacy home: new session button, last session continue card, Sessions,
  Players, Rankings, Scoreboard, Tournament, Instagram Post cards, and the
  `All communities` entry for the platform owner.
- `SettingsPage` (v2): members, role changes, invites, and join requests.
  The rating ledger is no longer here; use `/admin/ratings`.
- `OwnerSetupPage`: creates a community and shows the communities followed.

### Sessions

- `SessionListPage`: session list with player and game counts.
- legacy `SharedSessionPage`: per-game scores, mark played, swap players/slots/teams,
  absent, and per-player skip; data through the `legacy/queries` adapter.
- public `SharedSessionPage`: read-only based on the share code.
- legacy Scoreboard is still available at `/c/:slug/scoreboard`.

### Players

- `/players`: v2 roster, search, add player, and claims.
- `/players/:playerId`: detail, edit name/gender/tier/alias, merge, delete, and
  claim decisions. This is the only player management surface; the old admin
  `/admin/players` redirects here.

### Rankings

- legacy `RankingsPage`: points board + tier filter.
- legacy `RatingPlayerPage`: board rows, statistics, history, and badges.

### Tournaments

- `TournamentListPage` + `TournamentRouter`: list, classic and team editors,
  standings/bracket.
- `AdminTournamentsPage`: delete tournament.
- Tournament rating still goes through `/admin/ratings`.

### Post

- `InstagramPostPage`: choose a session or tournament, then render a post or story
  with the legacy templates (`legacy/utils/canvasPost.ts` and
  `legacy/config/instagramTemplates.ts`).
- Sizes and configuration still come from community config, not constants.
## 3. API operations

Source: `packages/contracts/openapi/core.yaml` + `community.yaml` → `api.yaml`;
the generated list is in `apps/api/src/routes_gen.nim`. Count: **75**
(`CONTRACT.sha256`, line `operations 75`).
Contract base URL: `https://api.qouver.com` (no path prefix) or
`http://127.0.0.1:8080` (`api.yaml`, `servers`).

The **Access** column follows `testdata/authz/matrix.yaml`; `session` means the
`majadu_session` cookie + community membership (except non-community operations).

### `auth`

| Method | Path | Access |
|---|---|---|
| `POST` | `/auth/start` | public* |
| `GET` | `/auth/callback` | public |
| `POST` | `/auth/logout` | session |
| `GET` | `/auth/me` | session |
| `GET` | `/auth/sessions` | session |
| `DELETE` | `/auth/sessions` | session |

**Note:** The implementation calls `startAuth` without a session check; the matrix marks it `session`.
In practice this is the login entry point, so it must be reachable without a cookie.

### `system`

| Method | Path | Access |
|---|---|---|
| `GET` | `/healthz` | public |
| `GET` | `/readyz` | public (DB check) |
| `GET` | `/version` | public |

### `community`

| Method | Path | Access |
|---|---|---|
| `GET` | `/communities` | session (own membership list) |
| `POST` | `/communities` | session + platform owner |
| `GET` | `/directory` | public* (opt-in entries; members see their own) |
| `POST` | `/c/{slug}/join-requests` | public* (always `202`, anti-enumeration) |
| `GET` | `/c/{slug}/join-requests` | session + admin |
| `PATCH` | `/c/{slug}/join-requests/{id}` | session + admin |
| `POST` | `/c/{slug}/invites` | session + admin |
| `POST` | `/invites/{token}/accept` | session |
| `GET` | `/c/{slug}/members` | session (member) |
| `PATCH` | `/c/{slug}/members/{userId}` | session + admin |
| `DELETE` | `/c/{slug}/members/{userId}` | session + admin |
| `GET` | `/c/{slug}/settings` | session (member) |
| `PATCH` | `/c/{slug}/settings` | session + admin |
| `GET` | `/c/{slug}/config` | session (member) |

**Note:** `GET /directory` and `POST …/join-requests` use an optional `currentUser`; without a
session both still answer (public list / `202`). The matrix marks them `session`
as the contract intent, not the handler behavior.

**Invite note:** login claims every invite addressed to that account's email,
so `POST /invites/{token}/accept` is idempotent for the owner's address: a token
that is already claimed still answers `201` with the granted membership, while
another address still gets `403 INVITE_EMAIL_MISMATCH`.

### `players`

| Method | Path | Access |
|---|---|---|
| `GET` | `/c/{slug}/players` | session (member) |
| `POST` | `/c/{slug}/players` | session + host/admin |
| `GET` | `/c/{slug}/players/{playerId}` | session (member) |
| `PATCH` | `/c/{slug}/players/{playerId}` | session + host/admin |
| `DELETE` | `/c/{slug}/players/{playerId}` | session + admin* |
| `GET` | `/c/{slug}/players/{playerId}/stats` | session (member) |
| `GET` | `/c/{slug}/players/{playerId}/achievements` | session (member) |
| `POST` | `/c/{slug}/players/{playerId}/claims` | session (member) |
| `GET` | `/c/{slug}/players/{playerId}/claims` | session (member) |
| `PATCH` | `/c/{slug}/players/{playerId}/claims/{claimId}` | session + admin* |
| `DELETE` | `/c/{slug}/players/{playerId}/claim` | session (member) |
| `POST` | `/c/{slug}/players/{playerId}/merge` | session + admin* |

**Note:** `DELETE player`, `PATCH claim`, and `POST merge` are admin only. `matrix.yaml`
states the same, and one table (`apps/api/src/route_access.nim`) is used by both the
dispatch and the test that compares it with the matrix. `createPlayer`/`PATCH player`
remain host/admin.

### `sessions`

| Method | Path | Access |
|---|---|---|
| `GET` | `/c/{slug}/sessions` | session (member) |
| `POST` | `/c/{slug}/sessions` | session + host/admin |
| `GET` | `/c/{slug}/sessions/{id}` | session (member) |
| `PATCH` | `/c/{slug}/sessions/{id}` | session + host/admin |
| `DELETE` | `/c/{slug}/sessions/{id}` | session + host/admin |
| `PUT` | `/c/{slug}/sessions/{id}/schedule` | session + host/admin |
| `PATCH` | `/c/{slug}/sessions/{id}/absent` | session + host/admin |
| `GET` | `/c/{slug}/sessions/{id}/games/{gameKey}` | session (member) |
| `PATCH` | `/c/{slug}/sessions/{id}/games/{gameKey}` | session + host/admin |
| `PATCH` | `/c/{slug}/sessions/{id}/games/{gameKey}/skip` | session + host/admin |
| `POST` | `/c/{slug}/sessions/{id}/swap` | session + host/admin |
| `POST` | `/c/{slug}/sessions/{id}/lock` | session + host/admin |
| `POST` | `/c/{slug}/sessions/{id}/unlock` | session + host/admin |
| `GET` | `/c/{slug}/sessions/{id}/standings` | session (member) |

`gameKey` = `{round}-{court}` (0-based), the same as the unique key in `session.games`
(`modules/session/schedule.nim:23-31`). Mutations use the session version `If-Match`; those
that support it also accept `Idempotency-Key`.

### `share`

| Method | Path | Access |
|---|---|---|
| `POST` | `/c/{slug}/sessions/{id}/share` | session + host/admin |
| `GET` | `/c/{slug}/sessions/{id}/share` | session + host/admin |
| `DELETE` | `/c/{slug}/sessions/{id}/share` | session + host/admin |
| `GET` | `/s/{code}` | public |

`GET /s/{code}` sends `session`, `community`, `games`, and `standings`.
`standings.items[]` contains `name`, `wins`, `losses`, `pointsFor`, `pointsAgainst`,
and `diff`: name, not player id, because a viewer has no session to
resolve a uuid. `standings` uses the same tally as
`GET /c/{slug}/sessions/{id}/standings`.

### `rankings`

| Method | Path | Access |
|---|---|---|
| `GET` | `/c/{slug}/rankings` | session (member) |
| `GET` | `/c/{slug}/rankings/{playerId}` | session (member) |
| `GET` | `/c/{slug}/rating-sources` | session + admin* |
| `PATCH` | `/c/{slug}/rating-sources/{id}` | session + admin |
| `POST` | `/c/{slug}/ratings/rebuild` | session + admin |
| `POST` | `/c/{slug}/sessions/{id}/rating` | session + admin |
| `DELETE` | `/c/{slug}/sessions/{id}/rating` | session + admin |
| `POST` | `/c/{slug}/tournaments/{id}/rating` | session + admin |
| `DELETE` | `/c/{slug}/tournaments/{id}/rating` | session + admin |
| `GET` | `/s/{code}/rankings` | public |
| `GET` | `/s/{code}/rankings/{playerId}` | public |

**Note:** `ratings` and `rating-sources` are admin only, and `matrix.yaml` states
the same; the access class is decided by `apps/api/src/route_access.nim`.

### `tournaments`

| Method | Path | Access |
|---|---|---|
| `GET` | `/c/{slug}/tournaments` | session (member) |
| `POST` | `/c/{slug}/tournaments` | session + host/admin |
| `GET` | `/c/{slug}/tournaments/{id}` | session (member) |
| `PUT` | `/c/{slug}/tournaments/{id}` | session + host/admin |
| `DELETE` | `/c/{slug}/tournaments/{id}` | session + host/admin |
| `PATCH` | `/c/{slug}/tournaments/{id}/matches/{matchId}` | session + host/admin |

`PUT` replaces the whole snapshot with `If-Match`; `PATCH` only touches one match
(`apps/api/src/app.nim:1780-1890`).

### `realtime`

| Method | Path | Access |
|---|---|---|
| `POST` | `/c/{slug}/sessions/{id}/ws-ticket` | session (member) |
| `POST` | `/s/{code}/ws-ticket` | public |
| `GET` | `/ws/c/{slug}/sessions/{id}` | session + single-use ticket |
| `GET` | `/ws/share/{code}` | public + single-use ticket |

WebSocket, **not** SSE. The ticket is issued by the `ws-ticket` endpoint, then used as the
`?ticket=…` query during upgrade; the ticket expires after use
(`apps/api/src/ws_ticket.nim`, `apps/api/src/app.nim:1676-1710`).

## 4. Routes outside the contract

The following handlers exist on the server but are not published in OpenAPI:

| Method | Path | Access | Source |
|---|---|---|---|
| `GET` | `/ops/ping` | ops bearer token | `apps/api/src/app.nim:1943-1946` |
| `DELETE` | `/c/{slug}/rating-sources/{id}` | session + admin | `apps/api/src/app.nim` `rating-sources` branch |

Do not add them to a public client without updating `core.yaml`/`community.yaml`
first; `./task contract-check` will not see them until the spec changes.
