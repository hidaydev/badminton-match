<div align="center">

# 🏸 Majadu

**Run a badminton club from one screen: sessions, scores, tournaments, and rank points.**

[![CI](https://github.com/hidaydev/badminton-match/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/hidaydev/badminton-match/actions/workflows/ci.yml)
[![Coverage gate](https://github.com/hidaydev/badminton-match/actions/workflows/coverage.yml/badge.svg?branch=main)](https://github.com/hidaydev/badminton-match/actions/workflows/coverage.yml)
![React](https://img.shields.io/badge/React-19-61DAFB?style=flat-square&logo=react&logoColor=black)
![TypeScript](https://img.shields.io/badge/TypeScript-6-3178C6?style=flat-square&logo=typescript&logoColor=white)
![Nim](https://img.shields.io/badge/Nim-2.4-FFE953?style=flat-square&logo=nim&logoColor=black)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18-4169E1?style=flat-square&logo=postgresql&logoColor=white)
![Tailwind CSS](https://img.shields.io/badge/Tailwind-4-38BDF8?style=flat-square&logo=tailwindcss&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-2ea44f?style=flat-square)

</div>

Majadu is a mobile-first multi-community app for recreational badminton: plan a
session, play it, score it, and let the ranking take care of itself. It runs as a
React PWA in front of a Nim API and one PostgreSQL database, with the HTTP
contract generated from OpenAPI.

| | |
|---|---|
| **Contract** | 76 operations, generated into Nim routes and the TypeScript client |
| **Schema** | 52 migrations, every table keyed by `community_id` |
| **Domain** | 9 modules: account, community, player, session, tournament, rating, achievement, share, platform |
| **Gates** | 1,518 Nim test cases in 140 suites, 144 parity cases, 170 end-to-end runs |

---

## ✨ What it does

| Area | Capability |
|---|---|
| **Sessions** | Courts, participants, schedule, per-game scores, skip, absent, swap, lock/unlock. Writes carry `If-Match` (OCC) and `Idempotency-Key`. |
| **Tournaments** | Classic (16 pairs → 4 groups → knockout) and team (6 teams × 6 tiers → groups + final, 3 rubbers per match), drawn and scored in the browser. |
| **Rank points** | v1's rolling 12-week window: best 10 entries per player, one entry per session or tournament, opponent strength from 8 sticky tiers, computed on read. |
| **Achievements** | Badge catalogue computed from match and tournament history, idempotent backfill. |
| **Players** | Canonical names, aliases, gender, sticky tier, claim/release/merge with admin approval and audit. |
| **Communities** | One deployment, many clubs: slug, memberships (`member`/`host`/`admin`), invites, join requests, per-club config overrides. |
| **Sharing** | Sealed share links (hash + encrypted code), public session and ranking pages, share-code redaction in access logs. |
| **Instagram posts** | Canvas-generated 1080×1350 posts and 1080×1920 stories for sessions and tournaments; sizes are constants in `apps/web/src/legacy/config/canvas.ts`. |
| **Live updates** | WebSocket ticket per session and per share link, `session.changed` frames. See [Status](#-status). |

Everything security-sensitive lives on the server: the browser holds one
`HttpOnly` `majadu_session` cookie and never sees a token.

---

## 🏗️ Repository layout

One monorepo, three deployables (web, scoreboard, API) and one business-number
registry in the database.

```text
majadu/
├── apps/
│   ├── web/                 React 19 · Vite 8 · Tailwind 4: the product
│   ├── scoreboard/          Standalone courtside scoring PWA
│   └── api/                 Nim 2.4 · mummy: REST + WebSocket
├── modules/                 Domain: account, community, player, session,
│                            tournament, rating, achievement, share, platform
├── shared/platform-lib/     db binder, clock, logger, metrics, uuidv7, sha256
├── packages/
│   ├── contracts/openapi/   core.yaml + community.yaml → api.yaml + client
│   └── web-client/          Generated TypeScript client
├── db/                      migrations (0001-0050), seeds, platform config
├── ops/                     Quadlet, Caddy, deploy/cutover/backup/restore/smoke
├── tools/                   dbtools, contract-gen, archcheck, ETL, parity,
│                            fixtures, mock-api, rehearsal
├── e2e/                     Playwright: a11y, visual, compatibility
├── testdata/                authz matrix, parity corpora (v1 frozen, v2 live)
├── docs/                    handbook, ops runbooks, decisions, design system
├── task                     Single command runner (`./task help`)
└── package.json             pnpm workspace root
```

**Rules that keep it small:** modules never import delivery layers, every table
carries `community_id`, every business number is read from
`platform.config`/`community.settings`, and generated files are only written by
their generator.

---

## 🚀 Local development

```bash
./task dev-db     # create roles + databases (one-off)
./task dev        # API on :8080 + OIDC stub on :19090 (--watch to rebuild)
pnpm dev          # web on http://localhost:5173
```

First run on a fresh database:

```bash
./task dev-db
MAJADU_PG_DSN=postgresql://$(whoami)@127.0.0.1:5432/bm2_dev \
  ./task bootstrap --sub stub-user-1 --email stub@example.com
```

The frontend calls `/api`; Vite proxies and strips it in dev, and `vercel.json`
rewrites it in production, so the session cookie stays first-party. Set
`VITE_API_BASE` only to bypass both.

---

## ✅ Gates

| Command | What it checks |
|---|---|
| `./task check` | `nim check`, archcheck and the unit suites; no database |
| `./task test` | unit + integration (needs `MAJADU_PG_DSN`); every suite gets its own database, `--timing` writes per-suite wall time, `--shard I/N` runs one slice, `WORKERS=N` farms the slices across worker databases |
| `./task ci` | check + build + test + contract fingerprint |
| `./task coverage` | line coverage per module, ratcheted against `coverage-baseline-<platform>.json` |
| `./task mutation` | applies each mutant in `tools/mutation/manifest.txt` and fails on an unlisted survivor |
| `./task parity v2 verify` | 143 recorded v2 cases; `parity verify` replays the frozen v1 corpus; `v2 canary` proves replay still rejects a wrong body |
| `./task e2e` | Playwright on iPhone 17 (WebKit) and POCO F5 (Chromium) |
| `pnpm check:web` | TypeScript, ESLint, Tailwind guard, Vitest with coverage thresholds, plus the scoreboard app |

CI runs seven jobs (`api-check`, `api-test`, `contract`, `web`, `e2e`, `image`,
`gate`), plus separate `coverage`, `nightly` and `release` workflows. Every job
is capped at 15 minutes and caches its toolchain.

---

## 🚢 Deployment

- **Web**: Vercel, built from `apps/web` on every push to `main`.
- **API**: rootless Podman on a VPS, started by a Quadlet unit and fronted by
  Caddy under `api.qouver.com/majadu/*`.

The release workflow builds the image once and records its digest in the GitHub
Release; `ops/scripts/deploy-vps.sh` pulls **by digest**, rotates `:local` to
`:prev`, restarts the unit and gates on `/readyz`. A push to `main` does not
deploy before the cutover: the script reads the production DSN and exits while it
still points at the v1 database.

The cutover from v1 (`bm`) to v2 (`bm2`) is manual, one-way, and scripted in
`ops/scripts/cutover.sh` with a runbook in [`docs/ops/cutover.md`](docs/ops/cutover.md).
Rollback is the `:v1-final` image, not source code.

A separate release candidate runs on the same host: branch
`release/2.0.0-rc.1`, its own Podman service, database and Vercel project.
`ops/scripts/deploy-vps-rc.sh` deploys it on every push to that branch. See
[`docs/ops/rc.md`](docs/ops/rc.md).

---

## 📌 Status

The v2 rewrite is complete: 76 contract operations, 52 migrations, backend and
frontend features wired end to end. The v1 Go tree is gone. The release
candidate `2.0.0-rc.1` runs on the RC instance; the production release chain
(tag, `release.yml`, digest deploy) has not yet run end to end on the VPS, and
production still runs v1 until the cutover.

Known gaps, tracked in [`docs/handbook/roadmap.md`](docs/handbook/roadmap.md):

- `platform.outbox` has no producer, so realtime is in-memory and the API must
  stay a single instance;
- the cutover rehearsal and the VPS-side checks are prepared but not executed.

---

## 📚 Documentation

Start at [`docs/README.md`](docs/README.md). The short version:

| Guide | For |
|---|---|
| [`docs/handbook/current-status.md`](docs/handbook/current-status.md) | What exists today: stack, contract, gates, infrastructure |
| [`docs/handbook/architecture.md`](docs/handbook/architecture.md) | Request pipeline, modules, realtime, layers |
| [`docs/handbook/data-model.md`](docs/handbook/data-model.md) | Schemas, tables, tenancy, config registry |
| [`docs/handbook/features-and-routes.md`](docs/handbook/features-and-routes.md) | Web routes and the 75 API operations |
| [`docs/ops/operations.md`](docs/ops/operations.md) | Access holders, incident format, routine checks |
| [`docs/ops/release.md`](docs/ops/release.md) | Release order, exit criteria, expand/contract, rollback |
| [`docs/ops/cutover.md`](docs/ops/cutover.md) | Cutover, rehearsal, rollback, consequences |
| [`docs/decisions.md`](docs/decisions.md) | Architecture decision record |
| [`docs/privacy.md`](docs/privacy.md) | What is stored, for how long, what anonymisation keeps |
| [`docs/design-system.md`](docs/design-system.md) | Tokens, typography, theme rules |
| [`apps/api/README.md`](apps/api/README.md) · [`apps/web/README.md`](apps/web/README.md) | Per-app layout and environment |

---

## 📄 License

Code and original artwork in `apps/web/public` are [MIT licensed](LICENSE);
[NOTICE](NOTICE) states the split. Decorative fonts are third-party files under
their own terms; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).