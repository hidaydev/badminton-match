# 🏸 Majadu

**Badminton session operations — from planning to podium.**

![React](https://img.shields.io/badge/React-19-61DAFB?style=flat-square&logo=react&logoColor=black)
![TypeScript](https://img.shields.io/badge/TypeScript-6-3178C6?style=flat-square&logo=typescript&logoColor=white)
![Vite](https://img.shields.io/badge/Vite-8-646CFF?style=flat-square&logo=vite&logoColor=white)
![Tailwind CSS](https://img.shields.io/badge/Tailwind-4-06B6D4?style=flat-square&logo=tailwindcss&logoColor=white)
![Go](https://img.shields.io/badge/Backend-Go-00ADD8?style=flat-square&logo=go&logoColor=white)
![PWA](https://img.shields.io/badge/PWA-Ready-5A0FC8?style=flat-square)

---

Majadu is a **mobile-first PWA** for running badminton sessions end-to-end. Configure courts and players, generate balanced doubles schedules with quality scoring, run live scoring with real-time sync, manage tournaments (classic & team), track **skill ratings (Glicko + 8-tier bands)** across seasons, and export branded social media content — all from one installable app.

---

## ✨ Features

### Session Lifecycle

| Step | What happens |
|------|-------------|
| **Setup** | Configure title, date, courts (1–6), players (4–40), game duration, per-court time windows with visual timeline |
| **Players** | Add individually or bulk-import from text. Gender (M/F), skill tier (**8-tier: D..A+**, sticky), inline rename, TBD slots |
| **Constraints** | Define forced pairings — **flexible** (generator picks slot) or **pinned** (locked to time + court) |
| **Generate** | 5-phase scheduling engine with quality analysis, retry logic, and 8-level tier balancing |

### Live Session Management

Publish and share via URL. Full operations console:

- 📊 Toggle played status & enter scores
- 🔄 Swap players, teams, or game slots
- 👤 Change individual players with cross-slot conflict detection
- 🚫 Mark absences (with void-game confirmation)
- 📈 Per-player stats (play count, sit count, partners, opponents)
- 🔒 Lock session to prevent edits (server-enforced; auto-lock when the date passes)

### Ratings & Leaderboard

- **Glicko-1-lite** engine (server-authoritative, idempotent, auditable)
- **8-tier bands** (D, D+, C, C+, B, B+, A, A+) — assigned tier never demotes below its letter
- Season system: live standings, frozen archives, close & start new season
- Player detail: rating sparkline, recent matches, and **career stats** (sessions, partners, opponents) in one place

### Tournament Manager

- **Classic**: 16 pairs → 4 groups → round-robin → knockout bracket (QF → SF → 3rd → Final)
- **Team**: 36 players (6 classes × 6 teams), manual team assignment, 9 group matches + 1 final
- Editable team names, member display, champion banner with trophy decoration
- PIC (person-in-charge) assignment · standings with head-to-head tiebreakers

### Admin Area

- Login once (password) — admin menus appear right on the home page
- Unlock/delete sessions · ingest/revert/rebuild ratings · close & start season
- Player management: add, rename, change tier, rebaseline, delete · delete tournaments

### Social Export

- Instagram post (1080×1350) and story (1080×1920) formats
- Upload photos with drag-to-reposition and pinch-to-zoom
- Leaderboard and tournament bracket visuals
- Branded templates with custom fonts

### Scoreboard

- Standalone fullscreen scoreboard with landscape lock
- Red/Blue sides with tap-to-increment
- Usable as overlay within tournament scoring

---

## 🛠 Tech Stack

| Layer | Technology | Why |
|-------|-----------|-----|
| **Framework** | React 19 + TypeScript 6 | Latest React with full type safety |
| **Build** | Vite 8 | Instant HMR, optimized builds |
| **Styling** | Tailwind CSS v4 | Semantic design tokens via `@theme` |
| **Typography** | IBM Plex Sans + IBM Plex Mono | Clean, accessible, professional |
| **Local State** | Zustand 5 (sliced) | Minimal boilerplate, persist middleware |
| **Server State** | TanStack React Query 5 | Optimistic updates, smart caching |
| **Routing** | React Router v7 | File-based route guards |
| **Backend** | Go (`majadu-api`, sister repo) | REST + Postgres, optimistic concurrency |
| **PWA** | vite-plugin-pwa | Installable, offline-capable |
| **DnD** | @dnd-kit/core | Accessible drag-and-drop |
| **Testing** | node:test (regression) + Go tests | `npm run check` · `make check` (majadu-api) |

---

## 🚀 Quick Start

```bash
# 1. Install dependencies
npm ci

# 2. Configure environment
cp .env.local.example .env.local
# Base URL API di-inject dari branch saat build (vite.config.ts) — lihat
# .env.local.example untuk override VITE_API_URL (mis. local dev).

# 3. Backend
# Frontend memanggil majadu-api (Go backend) — setup & jalankan di repo
# majadu-api (migrations SQL + `make run`). Skema DB: bm (prod) / bm_dev (dev).

# 4. Start development
npm run dev
```

The app runs at `http://localhost:5173` by default.

---

## 📜 Scripts

| Command | Description |
|---------|-------------|
| `npm run dev` | Start dev server with Vite HMR |
| `npm run build` | Type-check + production build |
| `npm run check` | Full validation: types + lint + tailwind + regression tests |
| `npm run check:regression` | Regression tests only (node:test) |

---

## 📁 Project Structure

```
src/
├── types/              # Domain types (zero dependencies)
├── config/             # Generator weights, canvas dims, 8-tier config, design tokens
├── i18n/               # Skeleton i18n (typed en dict, t()/useT(), zero deps)
├── generator/          # 5-phase schedule engine (pure TypeScript, zero store deps)
├── utils/              # Pure utilities: time, quality, standings, swap, canvas, stats
├── domain/ports/       # Repository interfaces (prepared for dependency injection)
├── queries/            # React Query hooks + REST client (majadu-api)
│   ├── endpoints.ts    # Raw REST fetch functions (retry method-aware)
│   ├── retry.ts        # Retry policy murni (testable)
│   ├── sessions.ts     # Session mutation/query hooks
│   ├── ratings.ts      # Rating/season hooks
│   ├── useOptimisticMutation.ts  # Factory hook for optimistic updates
│   └── types.ts        # CloudSnapshot, SessionMeta, PlayerSummary types
├── store/              # Zustand 5 slices (session, players, schedule, game, ui)
├── hooks/              # Custom hooks (useDebouncedPublish, etc.)
├── components/         # UI components
│   ├── summary/        #   SummaryModal sub-components
│   ├── tournament/     #   Tournament tab components
│   ├── generate/       #   Schedule view components
│   ├── ratings/        #   RatingTierBadge, RatingSparkline, CareerStats
│   └── admin/          #   AdminMenuGrid (home)
├── pages/              # Route pages
└── index.css           # Tailwind v4 @theme tokens + global styles

scripts/                # Build & dev tooling (canvas export, tailwind check, regression tests)
docs/                   # Handbook + design system + spec archive
```

Schema & migrasi DB disimpan di VPS (repo public tanpa SQL): `/srv/qouver/majadu/migrations/`.

---

## 🏗 Architecture

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  Presentation    │     │  Domain Logic    │     │  Infrastructure  │
│  (Pages / UI)    │────▶│  (Generator /    │────▶│  (Go backend via  │
│                  │     │   Utils)         │     │   REST)           │
└──────────────────┘     └──────────────────┘     └──────────────────┘
        │                        │                        │
   Zustand store           Pure functions           REST client
   React Query             Zero store deps         Optimistic updates
   Route guards            Injected config         Version concurrency
```

Backend: repo `majadu-api` (Go, `net/http` + pgx). Kontrak di `majadu-api/api/openapi.yaml`.

**Dependency rules:**

- `types/` → zero imports (leaf node)
- `generator/` + `utils/` → import only from `types/` and `config/`
- `queries/` → imports from `types/`, `config/`, `utils/` (never from `store/`)
- `store/` → imports from `types/`, `config/`, `utils/` (never from `queries/`)
- `pages/` → can import from anywhere

**Key patterns:**

- **Optimistic mutation factory** — `useOptimisticSessionMutation` eliminates boilerplate across 7+ hooks
- **Snapshot-based persistence** — full session state as `CloudSnapshot` JSON, version concurrency control
- **Debounced cloud publishing** — batches rapid changes (300ms trailing, 1s max delay)
- **Branded types** — `PlayerId`, `TimeString`, `GameKey` for type safety without runtime overhead
- **5-phase generator** — pinned → merge → spread → flexible → greedy fill with injectable scoring weights

---

## 🎨 Design System

Semantic design tokens defined in Tailwind v4 `@theme`:

| Token | Hex | Role |
|-------|-----|------|
| `--color-ground` | `#0b0e13` | Page background |
| `--color-surface` | `#14181f` | Cards, panels |
| `--color-elevated` | `#1c212b` | Inputs, inner cards |
| `--color-border` | `#2a313c` | Visible borders |
| `--color-border-subtle` | `#22272f` | Dividers, card borders |
| `--color-fg` | `#eef0f3` | Primary text |
| `--color-fg-dim` | `#8b939c` | Secondary text |
| `--color-accent` | `#e3b341` | Brand, CTA (gold) |
| `--color-success` | `#43a57d` | Positive states |
| `--color-error` | `#d65a5a` | Errors, destructive |

Full reference: [docs/design-system.md](docs/design-system.md)

---

## 🔒 Security Model

| Endpoint | Access | Behavior |
|----------|--------|----------|
| `GET /sessions` · `GET /sessions/{id}` | anon | Read-only list / snapshot |
| `PUT /sessions/{id}` | anon | Rejects writes when status ≠ 'draft' (lock) |
| `DELETE /sessions/{id}` | anon | Draft sessions only |
| `POST /sessions/{id}/lock` | anon | Host flow (server-enforced) |
| `POST /sessions/{id}/unlock` · `/delete` | **admin** | AdminGuard (Bearer `MAJADU_ADMIN_TOKEN`) |
| `POST /tournaments/{id}/delete` | **admin** | Delete + rating cleanup + rebuild |
| `POST /players` | anon | Register (TOCTOU-safe; optional 8-tier) |
| `PATCH /players/{id}/tier` · `/name` · `DELETE /players/{id}` | **admin** | Tier change (+rebuild) · rename · delete |
| `POST /ratings/*` (ingest/revert/finalize/rebuild/season/rebaseline) | **admin** | Bearer token |
| `GET /ratings/*` | anon | Public read (leaderboard, player, sources, seasons) |

Concurrency: advisory locks (`pg_try_advisory_xact_lock` / `pg_advisory_xact_lock`) +
`SELECT ... FOR UPDATE NOWAIT` + optimistic `If-Match`/ETag. Auth (JWT) is deferred —
single shared admin token; see `docs/handbook/backend-go-decision.md`.

---

## 📚 Documentation

| Document | Description |
|----------|-------------|
| [Handbook](docs/handbook/README.md) | Start here for project context |
| [Current Status](docs/handbook/current-status.md) | Latest state + handover doc |
| [Architecture](docs/handbook/architecture.md) | System design + clean architecture |
| [Data Model](docs/handbook/data-model.md) | Schema & TypeScript types |
| [Design System](docs/design-system.md) | Colors, typography, tokens, patterns |
| [Features & Routes](docs/handbook/features-and-routes.md) | Feature map + route structure |
| [Roadmap](docs/handbook/roadmap.md) | Phase plan and status |
| [Design Archive](DESIGN_ARCHIVE.md) | Keputusan desain terarsip (rating engine, 8-tier, admin, UI/UX) |
| [Backlog](BACKLOG.md) | Inventaris backlog & status |
| [E2E Testing Plan](E2E_TESTING_PLAN.md) | Rencana sweep end-to-end |
| [Backend](docs/handbook/backend-go-decision.md) | Keputusan arsitektur & fase migrasi Go |

---

## 📱 PWA

Majadu is installable as a Progressive Web App:

- **Android/Desktop**: Browser shows install prompt automatically
- **iOS**: Share → "Add to Home Screen"
- **Updates**: Prompt-based update banner when new version is available
- **Offline**: Local session creation works offline; cloud features require connectivity

---

## 🧪 Testing

```bash
# Type checking + linting + tailwind validation + regression tests
npm run check

# Backend verification lives in the majadu-api repo (make check + env-guarded
# integration tests) — see majadu-api/README.md.
```

---

## 📄 License

MIT — see [LICENSE](LICENSE).
