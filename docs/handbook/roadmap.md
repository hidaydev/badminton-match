# Roadmap

Status per **2026-09-19**. Riwayat detail per perubahan ada di [`current-status.md`](current-status.md)
dan git history.

## ✅ Fase selesai

- **Fase 1–6 (era Supabase/PostgREST)** — migrasi Apps Script → Supabase, parity, verifikasi
  tournament, security hardening, regression, export boundary. Ditutup saat Supabase dipensiunkan
  (2026-08-15).
- **Fase 7 — migrasi backend Go** — write-path, read-path, dan tournament sudah 100% di Go
  (2026-08-13 s/d 15), diverifikasi parity test live. Supabase di-drop; Postgres VPS jadi
  satu-satunya backend.
- **Granular live ops** — `scheduled_games` dengan OCC per baris, idempotency, outbox SSE
  (migrasi `000013`). Rasionalnya di [`revamp-grand-plan.md`](revamp-grand-plan.md).
- **Fase 8 — fitur produk** (2026-08 s/d 09), lihat [`current-status.md`](current-status.md):
  - Menu tournament list + wizard classic/team; 8-tier system (D..A+) tersambung FE+BE
  - Ratings & leaderboard Glicko-1-lite + season
  - Admin restructure: Sessions, Players, Ratings, Tournaments, Seasons
  - Auto-lock saat save; skip per-game mempertahankan skor; absent tidak dapat delta
  - Team tournament: penugasan tim manual, edit standings, champion banner, courts
  - Pagination: leaderboard, recent matches, session list
  - Migrasi prod `bm_dev` → `bm` (125 pemain, 27 sesi, 103 rated, 1 turnamen)
  - Auto-deploy webhook; SSE auto-reconnect catch-up; PWA Workbox offline
  - Achievements: skema, backfill, endpoint, badge UI (2026-09-13)
  - Team tournament photo post (2026-09-12, PR #20)
  - Nama pemain pakai canonical di read-path; snapshot nama tidak lagi dimutasi (2026-09-19)

## ⏳ Berikutnya (urut prioritas)

| # | Item | Status |
|---|------|--------|
| 1 | **Branch protection testing** — ruleset sudah dibuat, perlu di-test | Belum |
| 2 | **Auth** (ditunda): JWT/session middleware di Go, alur host tanpa friction | Ditunda |
| 3 | **Hardening lanjutan** kalau scope meluas: monitoring/alert API, staging env | Opsional |

## Catatan operasional

- Deploy: push `main` → GitHub webhook → `deploy/deploy-vps.sh` (build lokal + restart)
- Backup Postgres: timer harian 02:00 WIB
- Test: `go test ./...` (`apps/api`, 212 pass) · `npm run check:regression` (`apps/web`, 87 pass)
- Infrastruktur, DB, dan status test: [`current-status.md`](current-status.md)
