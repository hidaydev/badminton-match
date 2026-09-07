# Roadmap

Status per 2026-09-07. Fase era Supabase (1–6 di bawah) sudah selesai dan
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
- **Auto-lock on save** — lock when all scores entered (save-path; ticker auto-lock removed)
- **Gender in players table** — canonical gender, auto-fill in session creation
- **Team tournament improvements** — manual team assignment, standings editing, champion banner, courts
- **Pagination** — ratings leaderboard (100/page), recent matches (5/page), session list (5/page)
- **Supabase data import** — 125 players migrated to VPS
- **Prod migration** — bm_dev → bm (125 players, 27 sessions, 103 rated, 1 tournament)
- **Auto-deploy** — webhook → build lokal + restart di VPS (push `main` = deploy)
- **Checklist/Absent fix** — games tetap jalan, absent player tidak dapat rating delta
- **Version mismatch retry** — silent retry 1x sebelum error
- **Skip preserves scores** — per-game skip excludes player from rating, game counts for others (2026-08-30)
- **Rebaseline removed** — feature deleted (BE + FE) (2026-08-30)
- **Recent matches format** — "with teammate · vs opponent" instead of session title (2026-08-30)
- **absent_policy fix** — changed from `skip_game` → `skip_player`, all sessions re-ingested (2026-08-30)
- **NULL tier fix** — COALESCE in players list query prevents scan error (2026-08-30)
- **Auto-lock game sengaja tidak dimainkan** — game beres = ber-skor ATAU semua pemain di-skip; skip trigger auto-lock; past-date sweep di ticker (`LockPastDateDrafts`); career stats eksklusi game tanpa skor (2026-09-07)
- **Rating history null fix** — `COALESCE(array_agg, '{}')` untuk teammates/opponents + guard `?? []` di FE (2026-09-07)

## ⏳ Berikutnya (urut prioritas)

| # | Item | Status |
|---|------|--------|
| 1 | **Team tournament share/export** — Instagram post untuk team tournament | Belum |
| 2 | **Branch protection testing** — ruleset sudah dibuat, perlu di-test | Belum |
| 3 | **Auth** (ditunda): JWT/session middleware di Go, alur host tanpa friction | Ditunda |
| 4 | **Hardening lanjutan** kalau scope meluas: monitoring/alert API, staging env | Opsional |

## Catatan operasional

- Deploy: push `main` → GitHub webhook → `deploy/deploy-vps.sh` (build lokal + restart)
- Backup Postgres: timer harian 03:00 → `/srv/qouver/backups/postgres/`
- Test: `go test ./...` di `apps/api` · `npm run check` di `apps/web`
- Log: `/srv/qouver/apps/majadu/logs/main/app-YYYY-MM-DD.log`
