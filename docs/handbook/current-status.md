# Current Status

Last updated: **2026-11-16**. This document answers "what actually exists in the repo
today", not "what is planned".

Next entry points: [`architecture.md`](architecture.md),
[`data-model.md`](data-model.md), [`features-and-routes.md`](features-and-routes.md),
[`requirements.md`](requirements.md).

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

- **76 operations** in the contract: `packages/contracts/openapi/CONTRACT.sha256`
  (`operations 76`), generated output in `apps/api/src/routes_gen.nim`.
  Hand-written sources: `core.yaml` + `community.yaml`; generated output: `api.yaml`,
  `routes_gen.nim`, `packages/web-client/src/api.ts`.
- Every operation has a handler (compilation fails otherwise) and an authorization row in
  `testdata/authz/matrix.yaml`; `./task contract-check` guards the fingerprint.
- **60 migrations** in `db/migrations/` (`0001`–`0060`, the last one
  `0060_drop_removed_config_keys.sql`); seeds: `db/seeds/platform_config.sql`,
  `db/seeds/achievement_definitions.sql`.
- **36 config keys** in `modules/platform/config/registry.nim`, initial values in the seed;
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
  production the socket uses the API origin (`VITE_WS_BASE`, or the built-in
  `wss://api.qouver.com/majadu` fallback), because the Vercel rewrite does not
  carry the upgrade.

## 5. Gates

| Suite | Command | Note |
|---|---|---|
| `nim check`, archcheck, unit suites | `./task check` | no database; 76 unit suites (`./task check` prints the counts it will run) |
| Unit + integration | `./task test` | needs `MAJADU_PG_DSN`; 148 suites (76 unit, 72 integration; 2026-11-16), each suite on its own database; `--timing` and `--shard I/N` feed the three CI shards, which took 439 s and 575 s at two shards on `3afaa78e` and plan at 350 s each from the cost table |
| One module | `./task verify <module\|api>` | integration when the DB is present |
| Contract | `./task contract-check` | fingerprint + generated output |
| Parity | `./task parity verify` / `./task parity v2 verify` | frozen v1 71 cases/48 routes; v2 144 cases |
| Tournament ladder | `./task levels` | read/write `rating.levels`; no row = per-game formula |
| Coverage | `./task coverage` | per file, module and total ratchet against `coverage-baseline-<platform>.json` (89.14% of 21,295 executable lines, Linux baseline measured 2026-11-11, integration; one fresh database per suite, gcov captured per suite, ~10 minutes). The Nim number is **line coverage only**: gcov branch counts are printed next to it but are not part of the ratchet, so it must not be read as branch coverage. The gate also prints how many files sit below the 50% per-file floor and fails when that count grows (documents with an owner and an expiry live in `docs/handbook/coverage-debt.json`). The gate's 0.1 pp tolerance is published with the number: 89.14% means a lower bound of 89.04%, and a run between them is inside the noise band, not a regression. Every file also records its branch counters; they are reported, not ratcheted |
| Security | part of `./task test` | IDOR, escalation, CSRF, OIDC replay, rate limit, claims |
| Web | `pnpm check:web` | TypeScript, ESLint, Tailwind guard, Vitest |
| E2E | `./task e2e` | Playwright: a11y, visual, navigation, writes, OCC, offline, compatibility, role boundary; 170 runs across two devices and no skip, 65 of them drive a flow or the API socket (56 phone flows plus 9 API runs); snapshots per platform in `e2e/__screenshots__/{platform}/` |

E2E runs on two devices: **iPhone 17** (WebKit, 402×874, DPR 3) and
**POCO F5** (Chromium, 393×873, DPR 2.75), `maxDiffPixels: 0`.

## 6. CI

- `.github/workflows/ci.yml`: 9 jobs defined, 8 of them run on a push:
  `api-check` (which now also lints both parity corpora), `api-test` in three
  shards (Postgres 18.6), `web`, `e2e`, `image`, `supply-chain`, then `gate`;
  `mutation` runs on pull requests only. `gate` pages the webhook itself when
  main goes red, so there is no separate `notify` job. No job waits on another
  workflow (QOUVER_CICD_STANDARD §11.2, W9).
- No coverage workflow: the instrumented graph was removed on 2026-11-20, since
  no other repository carries one. `./task coverage` stays for a local run and
  `./task check` keeps the per-file floor through `coverage-debt.sh`.
- `.github/workflows/nightly.yml`: only the gates a push cannot afford, one job
  each so a cap on one does not swallow the others: the full mutation manifest
  (`./task mutation`, while `ci.yml` mutates only the changed prefixes), the whole
  parity corpus (`./task parity v2 canary` and `verify` on disposable databases),
  a repeated e2e for order dependence (`--repeat-each=3`), and the advisory
  scan. It used to run a second `./task ci` in one job; that command takes 20 to
  29 minutes on this runner, so the job was cancelled at the 15-minute cap before
  producing a verdict in each of the last five runs.
- `.github/workflows/release.yml`: triggered by a `v*` tag, builds the image once and
  writes the digest to the GitHub Release.
- All jobs use `timeout-minutes: 15`, use caching, and do not interpolate
  GitHub context directly into the shell. Every apt step skips itself when
  `dpkg -s` says the package is present and otherwise bounds each request
  (`Acquire::http::Timeout=15`, `Retries=3`), because an unbounded fetch inside a
  fifteen minute job is a latent timeout: on 2026-11-10 one coverage shard and one
  e2e job each spent fourteen minutes in apt and were reported as `cancelled`
  before a single test ran.
- `./task gate`: the same golden CI/CD contract the other seven repositories run, plus a
  shell syntax pass, the secret scan and the repo's own static checks
  (`task.d/gate.local.sh`: the contract fingerprint and the quoted counts). The
  `preflight` job runs this file, so "green on my machine" and "green in CI" are one
  claim. `./task gate-full` adds the whole `./task ci` suite and needs a database.
- `ops/scripts/contract-check.sh`: the static half of `QOUVER_CICD_STANDARD`
  v2.1 §11. It fails on W9 (a job polling another workflow), W10 (a Dependabot
  guard that is not limited to pull requests), W11 (the same gate command in two
  jobs) and W19 (an action not pinned to a full SHA), plus the universal contract:
  timeout, a secret scan, Dependabot coverage and the deploy invariants. It is a
  byte-identical copy of the standard's checker under the name the other seven use;
  `task.d/gate.sh` calls it.

## 7. Infrastructure

- **Deploy** (`ops/scripts/deploy-vps.sh`): only `refs/heads/main`; `flock`;
  `git fetch` + `reset --hard`; pull the image **by digest**; **`dbtools migrate` +
  `dbtools verify` + `dbtools seed` from that digest before rotating tags** (failure =
  release cancelled,
  `:local`/`:prev` untouched; the schema revision is recorded in `last-release.json`);
  rotate `:local` → `:prev`; restart the unit; `/readyz` gate; roll back to `:prev`
  on failure. The schema is not rolled back, so migrations must be expand/contract.
  **Cutover gate:** the script refuses to deploy unless the production env names
  `bm2`; production has run `bm2` since the cutover, and `bm` is the read-only v1
  archive the ETL reads.
- **RC: purged.** The release-candidate instance (`ops/scripts/deploy-vps-rc.sh`,
  `bootstrap-rc.sh`, `site-rc.caddy`, `majadu-rc-api.container`, database `bm2_rc`,
  `/srv/qouver/apps/majadu-rc`, branch `release/2.0.0-rc.1`) was removed on
  2026-11-21 by the owner's order. Its docs page went with it; a push to that
  branch now dispatches nowhere.
- **Cutover** (`ops/scripts/cutover.sh`): 14 named steps with a resume marker
  (`--from`), `:v1-final` tagged before v1 is stopped, Caddy maintenance, dump →
  `bm_staging`, roles + migrations + seed + owner, ETL + verify, `cutover_state`,
  swap env, swap the Caddy snippet, `/readyz`, smoke. Rollback: `rollback.sh`.
- **Unit**: `ops/systemd/majadu-api.container` (rootless, `Pull=never`,
  `MemoryMax=512M`, `StartLimit*`, `OnFailure=majadu-alert@%N.service`,
  `NoNewPrivileges`, `DropCapability=ALL`) + `majadu-alert@.service`.
- **Daily snapshot**: `majadu-snapshot.service` + `.timer` run
  `ranksnapshot` from the same image (`podman run --rm --pull=never`), so the
  movement arrow has a fresh snapshot every day. Production runs `bm2`, so the
  snapshot no longer depends on a manual run; the deploy installs the timer and
  enabling it is the operator step in [`../ops/cutover.md`](../ops/cutover.md).
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

The rewrite backlog is done; what remains is operations and measurement.

- **Operations, waiting on the VPS/time:** T-063 rehearsal (and therefore the
  T-060/061/065 evidence: production `caddy validate`, Quadlet parsing, digest
  `podman pull`, stopwatch rollback), T-074 soak (`ops/scripts/loadtest.mjs`
  reports p50/p95/p99 and RSS through `./task loadtest`; the 1 million request +
  50 watcher run against the VPS is still outstanding, so the ceiling stays
  unproven until it is archived), removal of `:v1-final` after 30 days (T-082),
  T-108 force-push postponed by owner decision.
- **Gaps outside the plan:** `platform.outbox` producer (realtime is still
  per-process). Coverage is measured after the gcov attribution fix, and CI
  judges `coverage-baseline-linux.json` (89.14% of 21,295 lines on 2026-11-11;
  every fall in covered lines was checked against the deletions that caused it).
  The lowest domains are `tools` 81.01%, `modules/player` 89.51% and `shared`
  91.55%.
- **Known data differences (accepted):** Salma, Youri, Zaid, and Firda
  differ from the v1 `bm.rank_snapshots` because the v1 ledger for the 2026-10-31 session
  was ingested before that session was edited. Owner decision: v2 follows current
  data, not the stale v1 ledger; 100 of 104 players stay exactly the same.
