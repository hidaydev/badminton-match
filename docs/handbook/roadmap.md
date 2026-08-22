# Roadmap

Status per 2026-08-22. Fase era Supabase (1–6 di bawah) sudah selesai dan
ditutup; detail historisnya ada di git history.

## ✅ Selesai

- **Fase 1–6 (era Supabase/PostgREST)** — migrasi Apps Script → Supabase,
  parity, tournament verification, security hardening, regression, export
  boundary. Ditutup saat Supabase dipensiunkan (2026-08-15).
- **Fase 7 → migrasi backend Go** — `backend-go-decision.md`; write-path,
  read-path, dan tournament sudah 100% di Go (2026-08-13 s/d 15), diverifikasi
  parity test live. Supabase di-drop; Postgres VPS jadi satu-satunya backend.
- **Menu tournament list** — `TournamentListPage` + routes `/tournaments`, `/tournaments/new` (classic/team wizard)
- **8-tier system** — D, D+, C, C+, B, B+, A, A+ (unified frontend + backend)
- **Ratings & Leaderboard** — Glicko-1-lite engine, 8-tier ClassBands, season system
- **Admin restructure** — 5 separate pages (Sessions, Players, Ratings, Tournaments, Seasons)
- **Auto-lock sessions** — lock when all scores entered or date passed
- **Gender in players table** — canonical gender, auto-fill in session creation
- **Team tournament improvements** — manual team assignment, standings editing, champion banner, courts
- **Pagination** — ratings leaderboard (100/page), recent matches (5/page), session list (5/page)
- **Supabase data import** — 125 players migrated to VPS
- **Prod migration** — bm_dev → bm (125 players, 27 sessions, 103 rated, 1 tournament)
- **Auto-deploy** — GitHub Actions → SSH → podman pull + restart (push = deploy)
- **Checklist/Absent fix** — games tetap jalan, absent player tidak dapat rating delta
- **Version mismatch retry** — silent retry 1x sebelum error

## ⏳ Berikutnya (urut prioritas)

| # | Item | Status |
|---|------|--------|
| 1 | **Team tournament share/export** — Instagram post untuk team tournament | Belum |
| 2 | **Branch protection testing** — ruleset sudah dibuat, perlu di-test | Belum |
| 3 | **Auth** (ditunda): JWT/session middleware di Go, alur host tanpa friction | Ditunda |
| 4 | **Hardening lanjutan** kalau scope meluas: monitoring/alert API, staging env | Opsional |

## Catatan operasional

- Deploy: push ke main/dev → GitHub Actions → SSH ke VPS → podman pull + restart
- Backup Postgres: timer harian 03:00 → `/srv/qouver/backups/postgres/`
- Test: `go test ./...` (backend) · `npm run check` (frontend)
- Log: `/srv/qouver/majadu/logs/{main,dev}/app-YYYY-MM-DD.log`
