# Roadmap

Status per **2026-11-04**. Riwayat perubahan ada di git history; rencana beku ada di
[`../plan/`](../plan/README.md) dan **tidak** diubah oleh handbook ini.

## ✅ Sudah ada di kode

- **Backend v2 (Nim)** — modul `account`, `community`, `player`, `session`, `tournament`,
  `rating`, `achievement`, `share`, `platform`; entrypoint `apps/api/src/main.nim`.
- **Kontrak 74 operasi** — `core.yaml` + `community.yaml` → `api.yaml`,
  `routes_gen.nim`, klien TS, fingerprint (`packages/contracts/openapi`).
- **Skema v2** — 14 migrasi (`db/migrations/0001`–`0014`), seed config dan achievement.
- **Auth & komunitas** — OIDC + cookie sesi, membership `member/host/admin`, invite,
  join request, settings, audit append-only.
- **Sesi** — API tulis (jadwal, skor, skip, absent, swap, lock/unlock, share) dengan
  `If-Match` + `Idempotency-Key`; klasemen server; halaman daftar/detail baca-saja.
- **Papan poin** — window 12 minggu / best 10 / minimal 3 game, filter tier, detail
  pemain + achievement.
- **Turnamen** — classic (16 pasangan, 4 grup, 32 match) dan team (6×6, 9 grup + final,
  3 partai), editor FE + ingest rating admin.
- **Ekspor** — post/story dari sesi atau turnamen, ukuran dari config.
- **Realtime** — WebSocket ticket sekali pakai, fan-out in-memory.
- **Gate** — `./task check`, `test`, `contract-check`, `pnpm check:web`, `./task e2e`
  (iPhone 17 + POCO F5), CI 6 job + gate.

## ⏳ Berikutnya (urut prioritas)

| # | Item | Kenapa / bukti |
|---|---|---|
| 1 | **UI tulis sesi** — buat sesi, isi jadwal, skor, skip, absent, swap, lock, share | `SessionPage` hanya membaca; tidak ada pemanggilan `PATCH/PUT/POST` sesi di `apps/web/src` |
| 2 | **Halaman players + admin** — daftar/klaim/merge pemain, anggota, settings | `/c/:slug/players` dan `/c/:slug/settings` masih `PlaceholderPage`; API-nya sudah ada |
| 3 | **Halaman share publik `/s/:code`** | rute ada, elemen masih placeholder; API `GET /s/{code}` + ranking share sudah ada |
| 4 | **Deployment v2** — env, unit quadlet, Caddy, cutover/backup/rollback | `ops/` masih memakai nama v1 (`bm`, `DATABASE_URL`, `/majadu`), bukan `MAJADU_PG_DSN`; lihat T-060/T-061/T-065 di `docs/plan/BACKLOG.md` |
| 5 | **Halaman owner communities** | `/owner/communities` masih placeholder |
| 6 | **Generator jadwal sesi** (bila diinginkan) | belum ada modul generator di v2; kontrak hanya menerima jadwal dari klien |

Dekomisi Go v1 (T-082) sudah selesai: source-nya dihapus, rollback memakai image
`:v1-final`.

## Catatan operasional

- Deploy (repo): push `main` → webhook → `ops/scripts/deploy-vps.sh` (build lokal,
  restart quadlet, healthcheck, rollback `:prev`). **Belum** disesuaikan dengan env Nim.
- Backup/restore/cutover: belum ada script di `ops/`; jangan menganggap prosedur v1
  berlaku.
- Test: `./task check` (tanpa DB) · `./task test` (dengan `MAJADU_PG_DSN`) ·
  `./task e2e` · `pnpm check:web`.
- Status & detail infrastruktur: [`current-status.md`](current-status.md).

## Riwayat singkat

- **v1** — backend Go + Postgres `bm`; kontrak snapshot/SSE; didokumentasikan di
  [`backend-go-decision.md`](backend-go-decision.md) (historis).
- **v2** — rewrite Nim di repo yang sama: kontrak OpenAPI, database `bm2`, multi-komunitas,
  WebSocket, config registry. Semua kode dan dokumen aktif saat ini mengacu ke v2.
