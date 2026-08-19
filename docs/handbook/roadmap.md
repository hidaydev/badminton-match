# Roadmap

Status per 2026-08-15. Fase era Supabase (1–6 di bawah) sudah selesai dan
ditutup; detail historisnya ada di git history.

## ✅ Selesai

- **Fase 1–6 (era Supabase/PostgREST)** — migrasi Apps Script → Supabase,
  parity, tournament verification, security hardening, regression, export
  boundary. Ditutup saat Supabase dipensiunkan (2026-08-15).
- **Fase 7 → migrasi backend Go** — `backend-go-decision.md`; write-path,
  read-path, dan tournament sudah 100% di Go (2026-08-13 s/d 15), diverifikasi
  parity test live. Supabase di-drop; Postgres VPS jadi satu-satunya backend.

## ⏳ Berikutnya (urut prioritas)

| # | Item | Status |
|---|------|--------|
| 1 | **Migrasi prod**: backup data `bm` (Supabase) → restore VPS → deploy backend `main` → arahkan frontend `main` → pensiunkan Supabase sepenuhnya | Belum |
| 2 | **Auth** (ditunda): JWT/session middleware di Go, alur host tanpa friction | Ditunda |
| 3 | **Menu tournament list** (ditunda): `GET /tournaments` + list page ala sessions | ✅ Selesai — `TournamentListPage` + routes `/tournaments`, `/tournaments/new` (classic/team wizard) |
| 4 | **Hardening lanjutan** kalau scope meluas: monitoring/alert API, staging env | Opsional |

## Catatan operasional

- Deploy dev: push `dev` → CI → image GHCR → auto-update timer 05:00 (atau `./scripts/deploy.sh dev`)
- Backup Postgres: timer harian 03:00 → `/srv/qouver/backups/postgres/`
- Test: `make check` (backend) · `npm run check` (frontend)
