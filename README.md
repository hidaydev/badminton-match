# 🏸 Majadu App

![React](https://img.shields.io/badge/React-19-61DAFB?style=flat-square&logo=react&logoColor=black)
![TypeScript](https://img.shields.io/badge/TypeScript-6-3178C6?style=flat-square&logo=typescript&logoColor=white)
![Vite](https://img.shields.io/badge/Vite-8-646CFF?style=flat-square&logo=vite&logoColor=white)
![Tailwind CSS](https://img.shields.io/badge/Tailwind-4-06B6D4?style=flat-square&logo=tailwindcss&logoColor=white)
![Supabase](https://img.shields.io/badge/Supabase-3FCF8E?style=flat-square&logo=supabase&logoColor=white)
![PWA](https://img.shields.io/badge/PWA-Ready-5A0FC8?style=flat-square)

> The operational app for running badminton sessions end to end — planning, scheduling, live scoring, tournaments, and social export.

---

## ✨ Features

### 🎯 Session Planning
- Configure courts, time slots, player count, and game duration
- Define fixed-match constraints with time & court pinning
- Generate balanced doubles schedules with quality analysis
- Retry generation for optimal partner/opponent distribution

### 🔴 Live Session Control
- Publish sessions and share via URL
- Mark games played, enter/revise scores
- Swap players, teams, and game slots
- Change individual players in specific games
- Mark players absent (excluded from leaderboard)
- **Lock session** to prevent further edits

### 📊 Player Stats & History
- Browse historical sessions
- Per-player career stats (W/L, points, partners, opponents)
- Real-time leaderboard with on-the-fly computation

### 🏆 Tournament
- 16 pairs → 4 groups → round-robin → knockout bracket
- Automatic bracket propagation
- Match PIC assignment
- Scoreboard overlay

### 📸 Social Export
- Instagram-style post & story graphics (1080×1350 / 1080×1920)
- Leaderboard export (absent players filtered)
- Tournament bracket & standings visuals

---

## 🛠️ Tech Stack

| Layer | Technology |
|-------|-----------|
| **Framework** | React 19 + TypeScript 6 |
| **Build** | Vite 8 |
| **Styling** | Tailwind CSS v4 |
| **Typography** | IBM Plex Sans + IBM Plex Mono (Google Fonts, non-blocking) |
| **State** | Zustand (local) + TanStack React Query (server) |
| **Routing** | React Router v7 |
| **Backend** | Supabase (PostgreSQL + PostgREST RPC) |
| **PWA** | vite-plugin-pwa |
| **DnD** | @dnd-kit/core |

---

## 🚀 Quick Start

### 1. Install

```bash
npm ci
```

### 2. Configure

```bash
cp .env.local.example .env.local
# Fill in VITE_SUPABASE_URL and VITE_SUPABASE_KEY
```

### 3. Apply Migrations

Apply the SQL migrations from `supabase/migrations/` to your Supabase project.

### 4. Run

```bash
npm run dev
```

---

## 🧪 Verification

```bash
# Static checks (types + lint + tailwind + regression)
npm run check

# E2E tests (Playwright — requires dev server)
npx playwright test

# Supabase smoke tests
source .env.local && npm run check:smoke
```

---

## 📁 Project Structure

```
src/
├── components/     # Shared UI components (SummaryModal, ShareButton, etc.)
│   └── ui/         # Reusable UI primitives (Card, Chip, Badge, EmptyState)
├── config/         # Tier config, design tokens, Instagram templates
├── generator/      # Schedule generation algorithm (pure TS)
├── hooks/          # Custom React hooks
├── pages/          # Route pages (Setup, Players, Generate, etc.)
├── queries/        # React Query hooks + Supabase RPC endpoints
├── store/          # Zustand stores (session, tournament)
└── utils/          # Utility functions (swap, standings, canvas, etc.)
e2e/                # Playwright E2E tests
scripts/            # Build scripts, regression tests, Instagram automation
```

---

## 🔐 Security Model

| RPC | Access | Notes |
|-----|--------|-------|
| `publish_session` | anon | Rejects writes when status ≠ 'draft' |
| `get_session` | anon | Read-only |
| `list_sessions` | anon | Returns lock status |
| `delete_session` | anon | Rejects deletion of locked sessions |
| `unlock_session` | service_role | Admin-only, not in UI |
| `register_player` | anon | Idempotent with TOCTOU fix |

---

## 📖 Documentation

- [Handbook](docs/handbook/README.md) — Start here
- [Current Status](docs/handbook/current-status.md) — Latest state
- [Design System](docs/design-system.md) — Colors, typography, components, tokens
- [Architecture](docs/handbook/architecture.md) — System design
- [Data Model](docs/handbook/data-model.md) — Schema & types
- [Features & Routes](docs/handbook/features-and-routes.md) — Feature map
- [Roadmap](docs/handbook/roadmap.md) — What's next

---

## ⚡ Performance

| Metric | Value |
|--------|-------|
| Initial JS (gzip) | ~107 KB (code-split) |
| CSS (gzip) | ~13 KB |
| PWA precache | ~638 KB |
| Logo assets | 14.5 KB + 88.1 KB (optimized PNG) |
| Font loading | Non-render-blocking, on-demand decorative |

---

## 🏗️ Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Local State   │ ←→  │  Domain Logic   │ ←→  │  Remote State   │
│    (Zustand)    │     │ (Generator/Utils)│     │   (Supabase)    │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        ↓                       ↓                       ↓
   localStorage           Pure Functions          PostgREST RPC
```

---

## 🤝 Relationship to MDEF

| App | Role |
|-----|------|
| **Majadu App** | Operations — session planning, live control, tournaments |
| **MDEF** | Analytics — canonical players, match history, ratings |

---

## 📄 License

Private project.
