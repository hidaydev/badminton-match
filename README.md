# 🏸 Majadu — Monorepo

**Badminton session operations — from planning to podium.**

Monorepo yang menggabungkan frontend (React/Vite) dan backend (Go) dalam satu repo:

| App | Lokasi | Stack |
|---|---|---|
| **Web** | [`apps/web/`](apps/web/README.md) | React 19, Vite 8, TypeScript 6, Tailwind v4, Zustand, TanStack Query |
| **API** | [`apps/api/`](apps/api/README.md) | Go 1.26, stdlib `net/http`, pgx/v5, Glicko-1-lite |

## Struktur

```text
majadu/
├── apps/
│   ├── web/            — Frontend PWA (deploy via Vercel)
│   └── api/            — Backend API (deploy via webhook, build lokal di VPS)
├── deploy/             — Webhook config, deploy-vps.sh, quadlet units, env templates
├── docs/               — Handbook + design system + arsip
└── Makefile / package.json — shortcut perintah pengembang
```

## Pengembangan Lokal

```bash
make dev        # web dev server (Vite, http://localhost:5173)
make dev-api    # Go backend (butuh DATABASE_URL — lihat apps/api/README.md)
make check      # validasi penuh (web: types+lint+tailwind+regression · api: vet+fmt+test)
```

## Deploy

- **Web**: Vercel — push ke `main` → build dari Root Directory `apps/web` (Ignored Build Step: skip bila `apps/web/` tidak berubah; command jalan dari dalam Root Directory, pathspec `.`).
- **API**: GitHub webhook → `webhook.service` di VPS → `deploy/deploy-vps.sh` → `podman build` lokal → restart quadlet `majadu-api`. Detail: `deploy/README`-nya di `deploy/webhook.json` + `MONOREPO_GITHUB_SETUP.md`.

## Branch Plan

- `main` — satu-satunya branch aktif (production). Branch `dev` di-sunset.
- Schema DB branch-based: `main` → `bm` (prod).

## Dokumentasi

- Web (fitur, arsitektur FE, design system): [`apps/web/README.md`](apps/web/README.md)
- API (endpoint, deploy, schema): [`apps/api/README.md`](apps/api/README.md)
- Handbook & keputusan arsitektur: [`docs/handbook/`](docs/handbook/README.md)