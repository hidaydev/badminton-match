# 🏸 Majadu

**Badminton session operations — from planning to podium.**

![React](https://img.shields.io/badge/React-19-61DAFB?style=flat-square&logo=react&logoColor=black)
![TypeScript](https://img.shields.io/badge/TypeScript-6-3178C6?style=flat-square&logo=typescript&logoColor=white)
![Vite](https://img.shields.io/badge/Vite-8-646CFF?style=flat-square&logo=vite&logoColor=white)
![Tailwind CSS](https://img.shields.io/badge/Tailwind-4-06B6D4?style=flat-square&logo=tailwindcss&logoColor=white)
![Supabase](https://img.shields.io/badge/Supabase-3FCF8E?style=flat-square&logo=supabase&logoColor=white)
![PWA](https://img.shields.io/badge/PWA-Ready-5A0FC8?style=flat-square)
![Playwright](https://img.shields.io/badge/E2E-Playwright-2EAD33?style=flat-square&logo=playwright&logoColor=white)

---

Majadu is a **mobile-first PWA** for running badminton sessions end-to-end. Configure courts and players, generate balanced doubles schedules with quality scoring, run live scoring with real-time sync, manage tournaments with knockout brackets, and export branded social media content — all from one installable app.

---

## ✨ Features

### Session Lifecycle

| Step | What happens |
|------|-------------|
| **Setup** | Configure title, date, courts (1–6), players (4–40), game duration, per-court time windows with visual timeline |
| **Players** | Add individually or bulk-import from text. Gender (M/F), skill tier (A–D), inline rename |
| **Constraints** | Define forced pairings — **flexible** (generator picks slot) or **pinned** (locked to time + court) |
| **Generate** | 5-phase scheduling engine with quality analysis, retry logic, and partner/opponent balancing |

### Live Session Management

Publish and share via URL. Full operations console:

- 📊 Toggle played status & enter scores
- 🔄 Swap players, teams, or game slots
- 👤 Change individual players with cross-slot conflict detection
- 🚫 Mark absences
- 📈 Per-player stats (play count, sit count, partners, opponents)
- 🔒 Lock session to prevent edits (server-enforced)

### Tournament Manager

- 16 pairs → 4 groups → round-robin → knockout bracket
- Automatic bracket propagation (QF → SF → 3rd → Final)
- PIC (person-in-charge) assignment per match
- Standings with head-to-head tiebreakers

### Player History

- Career stats across all sessions: W/L record, points for/against
- Top partners and opponents
- Session attendance history

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
| **Backend** | Supabase (PostgreSQL) | PostgREST RPC with advisory locking |
| **PWA** | vite-plugin-pwa | Installable, offline-capable |
| **DnD** | @dnd-kit/core | Accessible drag-and-drop |
| **E2E** | Playwright | Mobile viewport, Chromium headless |

---

## 🚀 Quick Start

```bash
# 1. Install dependencies
npm ci

# 2. Configure environment
cp .env.local.example .env.local
# Fill in VITE_SUPABASE_URL and VITE_SUPABASE_KEY

# 3. Apply database migrations
# Run the SQL files in supabase/migrations/ against your Supabase project
# Order (V2 baseline, 2026-08-11): 000001_functions.sql → 000002_schema.sql
# Functions first — the player_aliases CHECK constraint references normalize_player_name().

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
| `npm run check:smoke` | Live Supabase RPC smoke tests |
| `npx playwright test` | E2E tests (requires dev server running) |

---

## 📁 Project Structure

```
src/
├── types/              # Domain types (zero dependencies)
├── config/             # Generator weights, canvas dims, tier config, design tokens
├── generator/          # 5-phase schedule engine (pure TypeScript, zero store deps)
├── utils/              # Pure utilities: time, quality, standings, swap, canvas, stats
├── domain/ports/       # Repository interfaces (prepared for dependency injection)
├── queries/            # React Query hooks + Supabase RPC endpoints
│   ├── endpoints.ts    # Raw RPC fetch functions
│   ├── sessions.ts     # 14 session mutation/query hooks
│   ├── useOptimisticMutation.ts  # Factory hook for optimistic updates
│   └── types.ts        # CloudSnapshot, SessionMeta, PlayerSummary types
├── store/              # Zustand 5 slices (session, players, schedule, game, ui)
├── hooks/              # Custom hooks (useDebouncedPublish, etc.)
├── components/         # UI components
│   ├── summary/        #   SummaryModal sub-components
│   ├── tournament/     #   Tournament tab components
│   └── generate/       #   Schedule view components
├── pages/              # Route pages
├── infra/supabase/     # Supabase client setup
└── index.css           # Tailwind v4 @theme tokens + global styles

e2e/                    # Playwright E2E tests
scripts/                # Build scripts, regression tests, smoke tests
supabase/migrations/    # SQL migrations (squashed into 3 files)
docs/                   # Handbook + design system + spec archive
```

---

## 🏗 Architecture

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  Presentation    │     │  Domain Logic    │     │  Infrastructure  │
│  (Pages / UI)    │────▶│  (Generator /    │────▶│  (Supabase RPC)  │
│                  │     │   Utils)         │     │                  │
└──────────────────┘     └──────────────────┘     └──────────────────┘
        │                        │                        │
   Zustand store           Pure functions           PostgREST RPC
   React Query             Zero store deps         Optimistic updates
   Route guards            Injected config         Version concurrency
```

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
| `--color-ground` | `#0f172a` | Page background |
| `--color-surface` | `#1e293b` | Cards, panels |
| `--color-elevated` | `#334155` | Inputs, inner cards |
| `--color-fg` | `#f1f5f9` | Primary text (WCAG AA ~15.5:1) |
| `--color-fg-dim` | `#94a3b8` | Secondary text (WCAG AA ~7.1:1) |
| `--color-accent` | `#fbbf24` | Brand, CTA |
| `--color-accent-alt` | `#818cf8` | Interactive, links |

Full reference: [docs/design-system.md](docs/design-system.md)

---

## 🔒 Security Model

| RPC | Access | Behavior |
|-----|--------|----------|
| `publish_session` | anon | Rejects writes when status ≠ 'draft' |
| `get_session` | anon | Read-only snapshot fetch |
| `list_sessions` | anon | Returns lock status column |
| `delete_session` | service_role | Admin-only, rejects locked sessions |
| `unlock_session` | service_role | Admin-only, not in UI |
| `register_player` | anon | Idempotent with TOCTOU-safe re-query |

All mutations use advisory locks (`pg_try_advisory_xact_lock`) + `SELECT ... FOR UPDATE NOWAIT` for concurrency control.

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
| [Clean Code Backlog](CLEANCODE_BACKLOG.md) | 139/151 items complete |
| [Supabase Runbook](docs/handbook/bm-supabase-runbook.md) | Operational procedures |

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

# Live Supabase RPC smoke tests (requires .env.local)
npm run check:smoke

# E2E tests (requires dev server running on port 5173)
npx playwright test
```

---

## 📄 License

Private project.
