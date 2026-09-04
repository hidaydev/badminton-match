# 🏸 Majadu — Badminton Session Operations

**From planning to podium.** Majadu is a full-stack app for running badminton
sessions end-to-end: generate balanced doubles schedules, run live scoring with
real-time sync, manage tournaments (classic & team), track Glicko skill ratings
across seasons, and export branded social content.

One monorepo, one deploy pipeline:

| App | Lokasi | Stack | Deploy |
|---|---|---|---|
| **Web** | [`apps/web/`](apps/web/README.md) | React 19 · Vite 8 · TypeScript · Tailwind v4 · Zustand · TanStack Query · PWA | Vercel (Root Directory `apps/web`) |
| **API** | [`apps/api/`](apps/api/README.md) | Go 1.26 · stdlib `net/http` · pgx/v5 · Glicko-1-lite | VPS webhook → `podman build` lokal |

![React](https://img.shields.io/badge/React-19-61DAFB?style=flat-square&logo=react&logoColor=black)
![TypeScript](https://img.shields.io/badge/TypeScript-6-3178C6?style=flat-square&logo=typescript&logoColor=white)
![Go](https://img.shields.io/badge/Go-1.26-00ADD8?style=flat-square&logo=go&logoColor=white)
![Postgres](https://img.shields.io/badge/Postgres-18-4169E1?style=flat-square&logo=postgresql&logoColor=white)
![PWA](https://img.shields.io/badge/PWA-Ready-5A0FC8?style=flat-square)

---

## 📁 Struktur

```text
majadu/
├── apps/
│   ├── web/                 — Frontend PWA (Vercel)
│   └── api/                 — Backend Go + openapi.yaml (VPS webhook)
├── deploy/                  — Webhook config, deploy-vps.sh, quadlet units, env templates
├── docs/                    — Handbook, design system, keputusan arsitektur
├── .github/workflows/       — CI test-only (apps/api/**)
├── Makefile                 — Shortcut perintah pengembang
└── package.json             — npm scripts monorepo-level
```

## 🚀 Pengembangan Lokal

```bash
make dev          # Web dev server (Vite, http://localhost:5173)
make dev-api      # Go backend (butuh DATABASE_URL — lihat apps/api/README.md)
make check-web    # Web: types + lint + tailwind + regression
make check-api    # API: go vet + fmt + test
```

Perintah setara via npm: `npm run dev` · `npm run check:web` · `npm run check:api`.

> **Frontend ke backend:** base URL di-inject dari branch saat build
> (`main` → `https://api.qouver.com/majadu`). Override lokal lewat
> `VITE_API_URL` di `apps/web/.env.local` (lihat `.env.local.example`).

## 🚢 Deploy

- **Web** — Vercel: push ke `main` → build dari Root Directory `apps/web`.
  Ignored Build Step: `git diff --quiet HEAD^ HEAD -- . && exit 0 || exit 1`
  (jalan *dari dalam* Root Directory, jadi pathspec-nya `.`, bukan `apps/web/`).
- **API** — GitHub webhook (HMAC-SHA1) → `webhook.service` di VPS →
  [`deploy/deploy-vps.sh`](deploy/deploy-vps.sh) → `podman build` image lokal →
  restart quadlet `majadu-api`. Deploy hanya jika `apps/api/` berubah.

## 🌿 Branch & Schema

- `main` — satu-satunya branch aktif (production). Branch `dev` di-sunset.
- Schema DB branch-based: `main` → `bm` (prod). Dipilih via `MAJADU_DB_SCHEMA`, bukan hardcode.

## 📚 Dokumentasi

| Dokumen | Isi |
|---|---|
| [`apps/web/README.md`](apps/web/README.md) | Fitur FE, arsitektur, design system, script |
| [`apps/api/README.md`](apps/api/README.md) | Endpoint REST, kontrak, deploy API, schema |
| [`docs/handbook/`](docs/handbook/README.md) | Product overview, arsitektur, data model, roadmap |
| [`docs/design-system.md`](docs/design-system.md) | Design tokens & pola UI |
| [`docs/backend/`](docs/backend/) | Migrasi SQL terbaru + catatan migrasi |

## 📄 License

MIT — see [LICENSE](LICENSE).
