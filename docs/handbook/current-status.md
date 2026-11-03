# Current Status

Last updated: **2026-11-03** (sinkronisasi dokumen pasca-audit: papan poin BWF, migrasi `000013`–`000023`, route `/rankings`)

File handover tercepat. Mulai dari sini, lalu baca dokumen terkait.

## Repo & Branch

```text
badminton-match (monorepo)
├── apps/web (React 19 PWA, Vite 8, Tailwind v4) ──REST──▶ apps/api (Go 1.26, net/http+pgx) ──▶ Postgres VPS
├── apps/scoreboard (PWA scoring standalone, ~650 LOC, Vercel terpisah — tidak ada job CI-nya)
└── main (satu-satunya branch aktif)
```

- **Monorepo**: FE (`apps/web`) + BE (`apps/api`) + app scoring standalone (`apps/scoreboard`) dalam satu repo `hidaydev/badminton-match`.
- **`main`** — satu-satunya branch aktif (production). Branch `dev` & instance dev di-sunset (2026-09-04).
- **Web**: Vercel — Root Directory `apps/web`, auto-deploy dari push `main`.
- **API**: GitHub webhook → build lokal di VPS (`podman build` image `localhost/majadu-api:local`) → restart quadlet `majadu-api`.
- **API prod**: `https://api.qouver.com/majadu` (port 8080, schema `bm`).

---

## 🧪 Testing

| Suite | Command | Hasil |
|-------|---------|-------|
| Web regression | `pnpm check:regression` (`apps/web`) | **92 pass** |
| Backend Go | `go test ./...` (`apps/api`) | **210 pass** (10 paket) |
| Web build | `pnpm build:web` | PASS (PWA precache `dist/sw.js`) |

Test backend yang butuh Postgres di-skip otomatis tanpa `MAJADU_TEST_DATABASE_URL`; integration test
dijalankan terpisah terhadap database scratch.

---

## ✅ Baru selesai

### 2026-09-19 — Nama pemain dibaca dari canonical name

- Read-path sesi & team tournament resolve nama dari `players.canonical_name`:
  `COALESCE(p.canonical_name, sp.source_name)` di `store/session_read.go`, dan
  `COALESCE(p.canonical_name, ttp.player_name)` di `store/team_tournament.go`.
- `RenamePlayer` **tidak lagi** memutasi `session_players.source_name` /
  `tournament_team_players.player_name` (2026-09-18, `63d3c63`). Snapshot nama sengaja
  dibiarkan apa adanya supaya fingerprint (`SourceFingerprint` / `MatchKey`) stabil dan
  `ErrSourceChanged` tidak muncul saat edit sesi lama. Propagasi `tournament_pairs.pair_name`
  (classic tournament) tetap berjalan.
- Efek di prod: 32 pasangan / 81 baris langsung tampil dengan nama canonical, tanpa mutasi data.

### 2026-09-19 — Integration suite diperbaiki (`375bd9e`)

- Dari 5 pass / 24 fail → **32 pass**, idempoten (run kedua tanpa reset tetap 32 pass, 0 sesi bocor).
- Akar masalah: tanggal hardcoded di masa lampau (memicu auto-lock), cleanup yang bocor pada sesi
  locked, hardcode `bm_dev`, kontrak `skip_player`, dan mapping tier 8-level.
- Helper baru di `store/rating_integration_test.go`: `testSessionDate`, `saveLock`, `cleanupSession`.

### 2026-09-13 — Achievements

- Migrasi `000016_player_achievements.sql`; engine `apps/api/internal/domain/achievements.go`;
  definisi & badge di `apps/web/src/config/achievements.ts`,
  `components/ratings/AchievementBadge.tsx`, `AchievementDetailModal.tsx`.

### 2026-09-12 — Team tournament photo post (#20)

- Export post Instagram per match & standings team tournament
  (`apps/web/src/utils/teamTournamentPost.ts`, `drawTeamMatchPost` di `utils/canvasPost.ts`).

### 2026-09-10 — Audit fullstack & performa

- 9 isu security/performa + 13 bug diperbaiki: SSE single `SessionStore`, limit body JSON 10MB,
  masking error DB, queueing debounced publish, eviction rate limiter, setelan pool pgx,
  index `000015`, SSE catch-up via `/sessions/{id}/events` (broadcast `Watch` masih in-memory,
  aman karena API satu instance), dan strategi offline PWA Workbox.
- Dokumen audit (fullstack 09-10 & code-quality 09-18) **dihapus dari repo pada 2026-09-19**;
  arsipnya ada di git history.

---

## Infrastruktur

- **VPS Host**: `user@<VPS_IP>`
- **Containers**: `majadu-api` (prod:8080), `qouver-postgres` (5432)
- **Quadlet Config**: `~/.config/containers/systemd/majadu-api.container`
- **Deploy**: GitHub webhook → `ops/scripts/deploy-vps.sh` (build lokal + restart)
- **Migrasi SQL**: `000001`–`000012` di VPS (tidak di repo), `000013`–`000023` di [`docs/backend/`](../backend/)

---

## Database

| Database | Status |
|----------|--------|
| `bm` (prod) | Live — satu-satunya instance (dev `bm_dev` di-drop 2026-09-04) |

- Rating Config: `season_start 2026-05-23`, 8-tier ClassBands, `absent_policy=skip_player`.
  Papan poin: `rank_window_weeks 12`, `rank_best_n 10`, `rank_min_sessions 3` (nilai seed
  migrasi `000018`/`000022`). Glicko pensiun 2026-09-29 — tidak ada perhitungan rating.
- Index tambahan: lihat [`data-model.md`](data-model.md) §Performance Indexes.
