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

The only session storage is the `__Host-` `HttpOnly` cookie. `src/auth/api.ts`
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
- prod/preview: `vercel.json` rewrites `/api/:path*` to
  `https://api.qouver.com/:path*` **before** the SPA catch-all.

Set `VITE_API_BASE` to bypass both (for example `https://api.qouver.com`). Unset,
the client uses the same-origin `/api` path. Copy `.env.local.example` to
`.env.local` for local overrides.

## Vercel configuration

- No environment variable is required for the shell; `VITE_API_BASE` is optional
  and should stay unset on Vercel.
- The API must allow this origin in `security.allowed_origins` and register
  `<origin>/api/auth/callback` as the OIDC redirect URI.
- `vercel.json` also sets `Cache-Control: no-store` for `/`, `/index.html`, and
  `/s/*`, `Referrer-Policy: no-referrer` and `X-Robots-Tag: noindex` everywhere,
  and immutable caching under `/assets/*`.

### Not verifiable from this repo

The `Set-Cookie` path through the Vercel proxy must be checked on a **staging
alias that is registered as an OIDC redirect URI** — not on a random preview
deployment, whose host differs from the authenticated origin. That verification
is an operational step for whoever deploys; it cannot be proven by the tests
here.

## Layout

- `src/App.tsx` — auth gate plus routes generated from the manifest; new screens
  join by editing the manifest, not `App.tsx`.
- `src/routes.manifest.ts` — single route list (`path`, `labelKey`, `element`,
  `requiresAuth`, `roles`, `platformOwner`, `navGroup`). `visibleNav()` filters
  nav entries by the role from `GET /communities`; the platform owner sees
  owner-only entries but no community admin entry without an admin membership.
- `src/i18n/` — every user-visible string lives in `en.ts`; `t(key, vars?)` is
  typed by `MessageKey`. A test parses each `.tsx` file and fails on hardcoded
  JSX text or literal `placeholder`/`aria-label`/`title`/`alt` values.

## Visual direction

Every screen uses the tokens in `docs/design-system.md`; component and motion
rules live there too. `pnpm check:tailwind` fails on arbitrary values so a one-off
spacing or colour cannot sneak past the tokens.
