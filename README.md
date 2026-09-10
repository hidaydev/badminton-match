# 🏸 Majadu — Badminton Session Operations

**From planning to podium.** Majadu is a modern full-stack web application designed for running badminton sessions end-to-end: generate balanced doubles schedules, manage live scoring with real-time sync, run classic & team tournaments, track Glicko skill ratings across seasons, and export branded social media content.

![React](https://img.shields.io/badge/React-19-61DAFB?style=flat-square&logo=react&logoColor=black)
![TypeScript](https://img.shields.io/badge/TypeScript-5.8-3178C6?style=flat-square&logo=typescript&logoColor=white)
![Go](https://img.shields.io/badge/Go-1.26-00ADD8?style=flat-square&logo=go&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/Postgres-18-4169E1?style=flat-square&logo=postgresql&logoColor=white)
![Tailwind CSS](https://img.shields.io/badge/Tailwind-v4-38BDF8?style=flat-square&logo=tailwindcss&logoColor=white)
![PWA](https://img.shields.io/badge/PWA-Ready-5A0FC8?style=flat-square)

---

## ✨ Key Features

- ⚡ **Fair Schedule Generator**: Pure TS greedy scheduler algorithm scoring player repeats, tier spreads (8-tier D..A+), sit-out counts, and custom fix-match constraints.
- 🔄 **Real-Time Live Scoring**: Server-Sent Events (SSE) broadcasting match scores, absent status, and slot swaps instantly to connected clients.
- 🏆 **Tournament Engine**: 
  - **Classic Tournament**: 16 pairs → 4 groups round-robin → knockout bracket.
  - **Team Tournament**: 36 players across 6 skill classes → 6 balanced teams with manual assignment.
- 📈 **Glicko-1 Rating Engine**: Season-based rating calculation, automatic rating delta ingestion, 8-band rating tiers, and player career sparklines.
- 🎨 **Instagram Content Canvas**: Built-in HTML5 Canvas generator for exporting branded 1080×1350 posts and 1080×1920 stories.

---

## 🏗️ Repository Architecture

One monorepo, decoupled deployment pipelines:

| App | Location | Tech Stack | Deployment |
|---|---|---|---|
| **Web** | [`apps/web/`](apps/web/README.md) | React 19 · Vite 8 · TypeScript · Tailwind v4 · Zustand · TanStack Query · PWA | Vercel (`apps/web` root directory) |
| **API** | [`apps/api/`](apps/api/README.md) | Go 1.26 · stdlib `net/http` · pgx/v5 · Glicko-1 Engine | VPS Container (`podman`) via GitHub Webhook |

```text
majadu/
├── apps/
│   ├── web/                 — Mobile-first React 19 PWA
│   └── api/                 — Go 1.26 REST API & OpenAPI specification
├── deploy/                  — Quadlet container units, webhook scripts, env templates
├── docs/                    — Architecture handbooks, design system, audit archives
├── Makefile                 — Developer CLI shortcuts
└── package.json             — Monorepo root scripts proxy
```

---

## 🚀 Local Development

### Quick Start Commands

```bash
# Start Web Frontend dev server (Vite, http://localhost:5173)
make dev          # or npm run dev

# Start Go API backend (requires Postgres DATABASE_URL)
make dev-api      # or npm run dev-api

# Run full web check (TypeScript, Lint, Tailwind, 74 pure logic regression tests)
make check-web    # or npm run check:web

# Run full backend check (Go vet, formatting, unit & integration tests)
make check-api    # or npm run check:api
```

> **API Endpoint Configuration:**
> Frontend defaults to production API when built. Override locally via `VITE_API_URL` in `apps/web/.env.local` (see `apps/web/.env.local.example`).

---

## 🚢 Deployment Strategy

- **Web (Frontend):** Vercel automatic builds triggered on `main` branch pushes.
- **API (Backend):** Containerized via Podman on VPS. Deployment is triggered via GitHub Webhook (`deploy/deploy-vps.sh`) when changes to `apps/api/` occur.

---

## 📚 Documentation Index

| Guide | Description |
|---|---|
| [`apps/web/README.md`](apps/web/README.md) | Frontend architecture, state management, components, scripts |
| [`apps/api/README.md`](apps/api/README.md) | REST API endpoints, OpenAPI contract, database schema, rating engine |
| [`docs/handbook/`](docs/handbook/README.md) | Product overview, data models, routes, architectural decisions |
| [`docs/design-system.md`](docs/design-system.md) | UI tokens, color palettes, typography, theme rules |
| [`docs/audits/`](docs/audits/) | Fullstack technical audit reports & verification logs |

---

## 📄 License

[MIT License](LICENSE).
