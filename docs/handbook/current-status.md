# Current Status

Last updated: **2026-11-08**. This document answers "what actually exists in the repo
today", not "what is planned".

Next entry points: [`architecture.md`](architecture.md),
[`data-model.md`](data-model.md), [`features-and-routes.md`](features-and-routes.md),
[`roadmap.md`](roadmap.md).

## 1. Runtime

```text
apps/web   React 19.2 · Vite 8 · TypeScript 6 · Tailwind 4 · React Router 7
   │        browser → same-origin /api (Vite proxy in dev, vercel.json in prod)
apps/api   Nim 2.4.0 · mummy (HTTP + WebSocket) · db connector
   │
Postgres 18.6 · schema per domain (platform, community, player, session,
              tournament, rating, achievement, auth, account)
```

- **Backend = Nim** in `apps/api/src/`; `apps/api/Dockerfile` builds
  `apps/api/src/main.nim` (multi-stage Nim 2.4.0 → Debian bookworm-slim, uid 10001,
  port 8080).
- **The Go v1 code is removed** (T-082). Rollback uses the image
  `localhost/majadu-api:v1-final`, not source; the frozen v1 contract is in
  `testdata/parity/v1/`.
- **Scoreboard** (`apps/scoreboard`) is a separate PWA for recording scores on
  court; it shares no code with `apps/web` other than the score validation rules.

## 2. Contract & database

- **75 operations** in the contract: `packages/contracts/openapi/CONTRACT.sha256`
  (`operations 75`), generated output in `apps/api/src/routes_gen.nim`.
  Hand-written sources: `core.yaml` + `community.yaml`; generated output: `api.yaml`,
  `routes_gen.nim`, `packages/web-client/src/api.ts`.
- Every operation has a handler (compilation fails otherwise) and an authorization row in
  `testdata/authz/matrix.yaml`; `./task contract-check` guards the fingerprint.
- **36 migrations** in `db/migrations/` (`0001`–`0036`, the last one
  `0036_oauth_flow_key_id.sql`); seeds: `db/seeds/platform_config.sql`,
  `db/seeds/achievement_definitions.sql`.
- **34 config keys** in `modules/platform/config/registry.nim`, initial values in the seed;
  per-community overrides in `community.settings` may only narrow the platform.
- **Per-session scoring format** (ADR-012 in [`../decisions.md`](../decisions.md)): one
  schedule slot is one match containing 1..N sets. `0029_scoring_presets.sql`
  adds `session.game_sets` (one row per set), the `session.game_results` view,
  and the `scoring_preset` + `scoring_rules` snapshots on `session.sessions`; the
  preset list is in the `session.scoring_presets` config (MAJADU 30, Classic BO3 21, New
  BWF BO3 15) and the community default in `session.default_scoring_preset`. v1 sessions
  get a `legacy_v1` snapshot targeting 30; the old `score_a`/`score_b` columns
  are kept as the backfill source and the rollback path. `0030_scoring_grants.sql`
  gives the application role access to the new tables and view.
- Database names: production `bm2` (v1 archive `bm` read-only), local `bm2_dev`,
  `bm2_ops`, `bm2_e2e`, `bm2_parity_v2`; cutover uses `bm_staging`.

## 3. Frontend

The v1 frontend is fully restored in `apps/web/src/legacy/` (the pre-rewrite tree) on top of
the v2 API. All legacy routes still exist, now prefixed with `/c/:slug`. The old data layer
(`legacy/queries/endpoints.ts`) becomes an adapter: `CloudSnapshot` is assembled from
`GET /sessions/{id}`, granular writes use v2 endpoints, and old admin paths
are translated in `legacy/queries/admin.ts`.

- OIDC login + community shell (`/`, `/c/:slug`), community picker, i18n.
- **Sessions**: paginated list (filter and `load more` from the server), live session
  (`/c/:slug/s/:id`), scoreboard, 4-step wizard + 5-phase generator, a
  "Finish session" action in the summary (lock → ingest rating, reopen → revert),
  v2 share code (`/s/:code` for the public, Games/Standings tabs like the session screen
  in the app, refreshing every 10 seconds).
- **Players**: v2 roster (claims, merge, alias, edit, tier, delete) at
  `/c/:slug/players`; the old player admin page is retired and
  `/admin/players` redirects to the roster.
- **Rankings**: board + tier filter, player detail + badges + match history.
- **Tournaments**: list, classic and team editors, standings/bracket, admin rating.
- **Post**: Instagram Post editor (post and story) from a session or tournament.
- **Community settings**: members, roles, invites, join requests, config overrides.
  Invites have their own page, `/invites/:token` (outside the community shell);
  login also directly claims an invite addressed to that email, and
  re-accepting the same token by its owner returns the membership that was
  already granted.
- **Owner**: `/owner/communities` to create communities and see the ones followed.

Client state uses Zustand (wizard) and TanStack Query (server data). The service
worker/PWA is restored via `vite-plugin-pwa` (the old install/update banner is alive
again). v2-only code that has no v1 counterpart (Settings, player roster/claims, owner
communities) is still used; v2 pages that were never mounted in the router
(home, sessions, rankings, tournaments, export) were removed.

## 4. Realtime

- WebSocket, not SSE. Single-use tickets via `POST …/ws-ticket`, then upgrade
  to `/ws/c/{slug}/sessions/{id}` or `/ws/share/{code}`.
- The `session.changed` frame only carries `seq`; clients must re-read state.
- In-memory per-process fan-out hub → **the API must be a single instance**. `platform.outbox`
  already exists and is cleaned by the janitor, but there is no event producer yet. This is a
  deliberate constraint: one container per VPS, so cross-instance fan-out is not yet
  needed. Running two replicas without an outbox producer would leave some
  viewers without `session.changed`.
- **The web client uses WebSocket**: `useSessionRealtime` requests a single-use ticket,
  opens `/ws/c/{slug}/sessions/{id}`, and invalidates `['session', id]` on every
  `session.changed`; the `full`/`revoked` frames stop reconnection. While the socket
  is not connected (or after a drop) the page keeps polling every 5 seconds, so
  realtime is an accelerator, not a requirement. In dev, Vite proxies `/ws`; in
  production the socket uses the API origin (`VITE_WS_BASE`), because the Vercel rewrite does not
  carry the upgrade.

## 5. Gates

| Suite | Command | Note |
|---|---|---|
| `nim check`, archcheck, unit and database-backed suites | `./task check` | needs `MAJADU_PG_DSN` |
| Unit + integration | `./task test` | needs `MAJADU_PG_DSN`; 1,127 assertions in 110 suites (2026-11-08), each suite on its own database; `--timing` and `--shard I/N` are used by the two CI shards, which measured 219 s and 196 s against 406 s for one run |
| One module | `./task verify <module\|api>` | integration when the DB is present |
| Contract | `./task contract-check` | fingerprint + generated output |
| Parity | `./task parity verify` / `./task parity v2 verify` | frozen v1 71 cases/48 routes; v2 143 cases |
| Tournament ladder | `./task levels` | read/write `rating.levels`; no row = per-game formula |
| Coverage | `./task coverage` | per file, module and total ratchet against `coverage-baseline-<platform>.json` (88.09% of 19,360 executable lines, Linux baseline measured 2026-11-09, integration; one fresh database per suite, gcov captured per suite, ~10 minutes). The gate's 0.1 pp tolerance is published with the number: 88.09% means a lower bound of 87.99%, and a run between them is inside the noise band, not a regression |
| Security | part of `./task test` | IDOR, escalation, CSRF, OIDC replay, rate limit, claims |
| Web | `pnpm check:web` | TypeScript, ESLint, Tailwind guard, Vitest |
| E2E | `./task e2e` | Playwright: a11y, visual, navigation, writes, OCC, offline, compatibility, role boundary; 86 runs across two devices and no skip, 32 of them functional; snapshots per platform in `e2e/__screenshots__/{platform}/` |

E2E runs on two devices: **iPhone 17** (WebKit, 402×874, DPR 3) and
**POCO F5** (Chromium, 393×873, DPR 2.75), `maxDiffPixels: 0`.

## 6. CI

- `.github/workflows/ci.yml`: 7 jobs: `api-check`, `api-test` (Postgres 18.6),
  `contract`, `web`, `e2e`, `image`, then `gate`.
- `.github/workflows/coverage.yml`: instrumented build + ratchet, a separate
  workflow so the cache does not mix with the fast gate.
- `.github/workflows/nightly.yml`: full `./task ci` with a database service, plus `./task mutation` so a mutant that survives without an allowlist entry fails the night.
- `.github/workflows/release.yml`: triggered by a `v*` tag, builds the image once and
  writes the digest to the GitHub Release.
- All jobs use `timeout-minutes: 15`, use caching, and do not interpolate
  GitHub context directly into the shell.

## 7. Infrastructure

- **Deploy** (`ops/scripts/deploy-vps.sh`): only `refs/heads/main`; `flock`;
  `git fetch` + `reset --hard`; pull the image **by digest**; **`dbtools migrate` +
  `dbtools verify` from that digest before rotating tags** (failure = release cancelled,
  `:local`/`:prev` untouched; the schema revision is recorded in `last-release.json`);
  rotate `:local` → `:prev`; restart the unit; `/readyz` gate; roll back to `:prev`
  on failure. The schema is not rolled back, so migrations must be expand/contract.
  **Cutover gate:** while the production env still points at `bm`, the script stops
  before pull/restart.
- **RC** (`ops/scripts/deploy-vps-rc.sh`): branch `release/2.0.0-rc.1`, Podman service
  and database separate from production; all details are in
  [`../ops/rc.md`](../ops/rc.md).
- **Cutover** (`ops/scripts/cutover.sh`): 14 named steps with a resume marker
  (`--from`), `:v1-final` tagged before v1 is stopped, Caddy maintenance, dump →
  `bm_staging`, roles + migrations + seed + owner, ETL + verify, `cutover_state`,
  swap env, swap the Caddy snippet, `/readyz`, smoke. Rollback: `rollback.sh`.
- **Unit**: `ops/systemd/majadu-api.container` (rootless, `Pull=never`,
  `MemoryMax=512M`, `StartLimit*`, `OnFailure=majadu-alert@%N.service`,
  `NoNewPrivileges`, `DropCapability=ALL`) + `majadu-alert@.service`.
- **Daily snapshot**: `majadu-snapshot.service` + `.timer` run
  `ranksnapshot` from the same image (`podman run --rm --pull=never`), so the
  movement arrow has a fresh snapshot every day. Enabled after cutover.
- **Caddy**: `api.qouver.com` is one site with many `handle` blocks; the
  majadu snippet is a **handler block** imported inside that site, the `/majadu` prefix
  is kept. The one-time steps are in `ops/caddy/Caddyfile.api.qouver.com`.
- **Backup/restore/smoke**: `ops/scripts/{backup,restore,smoke}.sh`; the dump is verified
  with `pg_restore --list` before it is moved, file mode 600.
- **Rehearsal**: `tools/rehearsal/` + `./task rehearsal check`; `timings.json` is still
  `not_run` because it needs Podman + a maintenance window on the VPS.
- **Artifacts** not yet proven on the VPS: `caddy validate` on the production Caddyfile,
  Quadlet parsing, digest `podman pull`, and stopwatch rollback. See
  [`../ops/cutover.md`](../ops/cutover.md) §"What is not yet proven until the D-3 rehearsal".

## 8. Remaining work

The rewrite backlog is done; what remains is in [`roadmap.md`](roadmap.md). In short:

- **Operations, waiting on the VPS/time:** T-063 rehearsal (and therefore the
  T-060/061/065 evidence), T-074 soak, removal of `:v1-final` after 30 days (T-082),
  T-108 force-push postponed by owner decision.
- **Gaps outside the plan:** `platform.outbox` producer (realtime is still
  per-process). Coverage is measured after the gcov attribution fix, and CI
  judges `coverage-baseline-linux.json` (88.09% of 19,360 lines on 2026-11-09).
  The lowest domains are `tools` 80.55%, `modules/player` 88.29% and
  `modules/session` 90.31%.
- **Known data differences (accepted):** Salma, Youri, Zaid, and Firda
  differ from the v1 `bm.rank_snapshots` because the v1 ledger for the 2026-10-31 session
  was ingested before that session was edited. Owner decision: v2 follows current
  data, not the stale v1 ledger; 100 of 104 players stay exactly the same.
