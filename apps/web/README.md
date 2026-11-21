# Majadu web

React 19 + Vite 8 + Tailwind 4. Authentication shell, community picker, session
play-by-play, rankings, tournaments, player admin, share pages, and the post
editor all live here. The restored v1 screens sit under `src/legacy/`; the v2
screens that stayed (settings, roster, owner setup) sit under `src/pages/`.
`src/App.tsx` mounts every route, and `src/routes.manifest.ts` only tells which
community a pathname belongs to.

## Scripts

| Command | Purpose |
|---------|---------|
| `pnpm dev` | Vite dev server on port 5173 with the `/api` proxy |
| `pnpm build` | Type-check (`tsc -b`) and build to `dist/` |
| `pnpm check:types` | `tsc -b --pretty false` |
| `pnpm check:lint` | ESLint |
| `pnpm check:tailwind` | rejects arbitrary Tailwind values |
| `pnpm test` | Vitest (jsdom) |
| `pnpm check` | all four, in order |

## Login flow

1. `GET /api/auth/me` decides whether a session exists. `401` renders the login
   screen; anything else renders the shell.
2. `POST /api/auth/start` with `{ returnTo }` (current path, same origin) returns
   `{ authorizeUrl }`; the browser navigates there.
3. Google redirects to `GET /api/auth/callback`, the API exchanges the code
   server-side and sets the session cookie.
4. `POST /api/auth/logout` revokes the session and clears local state.

The only session storage is the `majadu_session` `HttpOnly` cookie. `src/auth/api.ts`
sends `credentials: 'include'` on every call and never touches
`localStorage`/`sessionStorage`. A test asserts both stores stay empty.

The bundle also sends `X-API-Version: 2` (`API_VERSION` in `src/auth/api.ts`) so
the API can reject outdated clients with `410 CLIENT_OUTDATED`. The header name
is provisional until the generated contract pins it.

## `/api` proxy

The browser never calls `api.qouver.com` for HTTP (ADR-021), so the session
cookie stays first-party:

- dev: `vite.config.ts` proxies `/api` to `http://127.0.0.1:8080` and strips the
  `/api` prefix (the API itself has no prefix).
- prod/preview: `vercel.json` rewrites `/api/:path*` to the API host
  **before** the SPA catch-all. The `/majadu` segment is required: Caddy serves
  the API only under `/majadu/*` and strips the prefix before proxying
  (`ops/caddy/site-v2.caddy`), so a rewrite to the bare host reaches nothing.
  The production value is `https://api.qouver.com/majadu/:path*`, which is what
  the committed file holds on `main`. The RC instance had its own value
  (`/majadu-rc/*`); it was purged on 2026-11-21, so no rewrite may carry that
  segment again (`task.d/ci-guards.sh` fails a tag that does).

Set `VITE_API_BASE` to bypass both. It must carry the same prefix, for example
`https://api.qouver.com/majadu`; without `/majadu` every call 404s. Unset, the
client uses the same-origin `/api` path. Copy `.env.local.example` to
`.env.local` for local overrides.

## Vercel configuration

- `VITE_API_BASE` should stay unset: the rewrite already keeps HTTP traffic
  same-origin, which is what keeps the session cookie first-party.
- **`VITE_WS_BASE` overrides the socket host**; without it the client falls back
  to `wss://api.qouver.com/majadu` on any deployed page. A Vercel rewrite cannot
  carry a WebSocket upgrade, so the session socket has to reach the API host
  directly (the same `/majadu` prefix applies). The fallback exists because the
  Vercel project that serves `majadu.vercel.app` is not configured from here;
  before it, an unset value made `socketBase()` return the page origin, where
  `/ws/...` is a static asset: the socket never connected and the session page
  silently degraded to its 5 s poll. `localhost` keeps the page origin so the
  dev proxy carries the upgrade. The CSP in `vercel.json` allows
  `wss://api.qouver.com`; pointing `VITE_WS_BASE` at another host also means
  adding that host to `connect-src` there.
- The API must allow this origin in `security.allowed_origins` and register
  `<origin>/api/auth/callback` as the OIDC redirect URI.
- `vercel.json` also sets `Cache-Control: no-store` for `/`, `/index.html`, and
  `/s/*`, `Referrer-Policy: no-referrer` and `X-Robots-Tag: noindex` everywhere,
  and immutable caching under `/assets/*`.
- `ignoreCommand` in `vercel.json` watches `apps/web`, `packages` **and the root
  `VERSION`**, because `build-info.mjs` bakes the version into the bundle at
  build time. Without it a release that only bumps `VERSION` is skipped as
  "no web change" and the login footer keeps reporting the previous version
  (v2.0.1 shipped that way). The comparison starts at `VERCEL_GIT_PREVIOUS_SHA`
  (the last successful deployment on this branch), not `HEAD^`: a release commit
  is often followed on `main` by a CI-only commit, and `HEAD^..HEAD` then sees
  neither `VERSION` nor `apps/web` and skips the release — v2.0.6 shipped that
  way. An empty `VERCEL_GIT_PREVIOUS_SHA` (first build on a branch) exits
  non-zero and builds. It overrides the project's Ignored Build Step in the
  dashboard.
- The command verifies the base commit exists before it diffs. Vercel clones
  shallow, and it treats an ignore-command exit code other than `0` (skip) or
  `1` (build) as a deployment error: `git diff` against a commit the clone does
  not hold exits `128`, which failed every production deploy of `badmin` after
  the gap to the previous successful deployment grew past the clone depth
  (2026-11-21). A missing or empty base now falls through to `1` and builds.

### Not verifiable from this repo

The `Set-Cookie` path through the Vercel proxy must be checked on a **staging
alias that is registered as an OIDC redirect URI** — not on a random preview
deployment, whose host differs from the authenticated origin. That verification
is an operational step for whoever deploys; it cannot be proven by the tests
here.

## Layout

- `src/App.tsx` — the route table and the auth gate. `src/routes.manifest.ts`
  holds only pathname helpers (`communitySlugFromPath`, `communityHref`) so
  route *shapes* have one implementation; adding a screen still means editing
  `App.tsx` and `e2e/visual.routes.ts`, and `src/legacy/routes.test.tsx` pins the
  legacy routes.
- `src/api/errors.ts` — the single `ApiError` class plus the
  `CLIENT_OUTDATED`/`SESSION_EXPIRED` shell events; both HTTP transports throw
  and signal through it.
- `src/i18n/` — every user-visible string lives in `en.ts`; `t(key, vars?)` is
  typed by `MessageKey`. A test parses each `.tsx` file and fails on hardcoded
  JSX text or literal `placeholder`/`aria-label`/`title`/`alt` values.

## Visual direction

Every screen uses the tokens in `docs/design-system.md`; component and motion
rules live there too. `pnpm check:tailwind` fails on arbitrary values so a one-off
spacing or colour cannot sneak past the tokens.
