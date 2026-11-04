# 🏸 Majadu — Badminton Session Operations

**From planning to podium.** Majadu is a modern full-stack web application designed for running badminton sessions end-to-end: generate balanced doubles schedules, manage live scoring with real-time sync, run classic & team tournaments, track rank points on a rolling 12-week leaderboard, and export branded social media content.

![React](https://img.shields.io/badge/React-19-61DAFB?style=flat-square&logo=react&logoColor=black)
![TypeScript](https://img.shields.io/badge/TypeScript-6-3178C6?style=flat-square&logo=typescript&logoColor=white)
![Nim](https://img.shields.io/badge/Nim-2.2-FFE953?style=flat-square&logo=nim&logoColor=black)
![PostgreSQL](https://img.shields.io/badge/Postgres-18-4169E1?style=flat-square&logo=postgresql&logoColor=white)
![Tailwind CSS](https://img.shields.io/badge/Tailwind-v4-38BDF8?style=flat-square&logo=tailwindcss&logoColor=white)
![PWA](https://img.shields.io/badge/PWA-Ready-5A0FC8?style=flat-square)

---

## ✨ Key Features

- ⚡ **Fair Schedule Generator**: Pure TS greedy scheduler algorithm scoring player repeats, tier spreads (8-tier D..A+), sit-out counts, and custom fix-match constraints.
- 🔄 **Real-Time Live Scoring**: a WebSocket channel per session (and per share link) pushes scores, absences and swaps to every watcher.
- 🏆 **Tournament Engine**: 
  - **Classic Tournament**: 16 pairs → 4 groups round-robin → knockout bracket.
  - **Team Tournament**: 36 players across 6 skill classes → 6 balanced teams with manual assignment.
- 📈 **Rank Points Leaderboard**: BWF-style rolling 12-week window (best 10 sessions), 8-band skill tiers, and player career stats.
- 🏅 **Player Achievements**: Badge collection computed from match & tournament history (attendance, volume, opponent, tournament, tier, rank, social).
- 🎨 **Instagram Content Canvas**: Built-in HTML5 Canvas generator for exporting branded 1080×1350 posts and 1080×1920 stories.

---

## 🏗️ Repository Architecture

One monorepo, decoupled deployment pipelines:

| App | Location | Tech Stack | Deployment |
|---|---|---|---|
| **Web** | [`apps/web/`](apps/web/README.md) | React 19 · Vite 8 · TypeScript · Tailwind v4 · React Router · PWA | Vercel (`apps/web` root directory) |
| **API** | [`apps/api/`](apps/api/README.md) | Nim 2.2 · mummy HTTP · Postgres (schema `majadu_v2`) · rank point engine | VPS container (Podman/Quadlet) via GitHub Webhook |
| **Scoreboard** | [`apps/scoreboard/`](apps/scoreboard) | React 19 · Vite · Tailwind v4 · PWA (standalone courtside scoring) | Vercel (`apps/scoreboard` root directory) |

```text
majadu/
├── apps/
│   ├── web/                 — Mobile-first React 19 PWA
│   ├── scoreboard/          — Standalone courtside scoreboard PWA
│   └── api/                 — Nim REST API, contract-generated routes
├── modules/                 — Domain modules (Clean Architecture, no delivery imports)
├── shared/platform-lib/     — db, clock, logger, metrics, uuidv7, sha256
├── packages/contracts/      — OpenAPI specs and the generated TS client
├── db/                      — SQL migrations and config seeds
├── ops/                     — Quadlet unit, deploy/smoke/rotate scripts, env template
├── docs/                    — Handbook, design system, ops and privacy docs
├── tools/                   — dbtools, contract-gen, archcheck, fixtures, soak, ETL
├── task                     — Single command runner (`./task help`)
└── package.json             — Monorepo root scripts proxy (`pnpm` workspace)
```

---

## 🚀 Local Development

### Quick Start Commands

Everything backend goes through `./task`; the frontend keeps its own Vite
scripts. `./task help` lists every target.

```bash
./task dev-db     # one-off: create the local roles and databases
./task dev        # API on :8080 + OIDC stub on :19090 (add --watch to rebuild)
pnpm dev          # Vite on http://localhost:5173, hot reload
```

One-time bootstrap (already done on this machine, needed on a fresh one):

```bash
./task dev-db
MAJADU_PG_DSN=postgresql://$(whoami)@127.0.0.1:5432/bm2_dev \
  ./task bootstrap --sub stub-user-1 --email stub@example.com
```

| Command | What it does |
|---|---|
| `./task check` | format, `nim check`, archcheck, unit tests — no database |
| `./task test` | unit + integration tests (needs `MAJADU_PG_DSN`) |
| `./task ci` | check + build + test + contract check |
| `./task e2e` | Playwright a11y, visual and compatibility regression |
| `pnpm check:web` | TypeScript, ESLint, Tailwind guard, Vitest |

> **API endpoint configuration:** the frontend calls `/api` and Vite proxies it
> to the API, so no environment variable is needed for local work. A deployment
> sets `VITE_API_BASE` instead.
>
> **Hot reload:** Vite reloads the frontend. Nim has no hot reload; `./task dev
> --watch` rebuilds and restarts the API when a `.nim` file changes.

---

## 🚢 Deployment Strategy

- **Web (Frontend):** Vercel automatic builds triggered on `main` branch pushes.
- **API (Backend):** container on the VPS, built by `ops/scripts/deploy-vps.sh` from a GitHub webhook on `refs/heads/main`, with a health gate and a `:prev` image for rollback.

---

## 📚 Documentation Index

| Guide | Description |
|---|---|
| [`apps/web/README.md`](apps/web/README.md) | Frontend architecture, state management, components, scripts |
| [`apps/api/README.md`](apps/api/README.md) | API layout, environment contract, database schema |
| [`docs/handbook/`](docs/handbook/README.md) | Product overview, data model, routes, decisions |
| [`docs/ops/operations.md`](docs/ops/operations.md) | Access holders, incident format, routine checks |
| [`docs/privacy.md`](docs/privacy.md) | What is stored, for how long, and what anonymisation keeps |
| [`docs/design-system.md`](docs/design-system.md) | UI tokens, color palettes, typography, theme rules |

---

## 📄 License

The source code and the original artwork in `apps/web/public` are
[MIT licensed](LICENSE). [NOTICE](NOTICE) states the exact split.

The decorative fonts are third-party files with their own terms and are **not**
covered by MIT — see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
