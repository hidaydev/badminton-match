# Current Status

Terakhir diperbarui: **2026-11-04**. Dokumen ini menjawab "apa yang benar-benar
ada di repo hari ini", bukan "apa yang direncanakan". Rencana beku ada di
[`../plan/`](../plan/README.md).

Pintu masuk berikutnya: [`architecture.md`](architecture.md),
[`data-model.md`](data-model.md), [`features-and-routes.md`](features-and-routes.md),
[`roadmap.md`](roadmap.md).

## 1. Runtime

```text
apps/web   React 19.2 · Vite 8 · TypeScript 6 · Tailwind 4 · React Router 7
   │        browser → same-origin /api (Vite proxy di dev, vercel.json di prod)
apps/api   Nim 2.4.0 · mummy (HTTP + WebSocket) · db connector
   │
Postgres 18.6 · skema per domain (platform, community, player, session,
              tournament, rating, achievement, auth, account)
```

- **Backend = Nim** di `apps/api/src/`; `apps/api/Dockerfile` membangun
  `apps/api/src/main.nim` (multi-stage Nim 2.4.0 → Debian bookworm-slim, uid 10001,
  port 8080).
- **Kode Go v1 sudah dihapus** (T-082). Rollback memakai image
  `localhost/majadu-api:v1-final`, bukan source; kontrak v1 yang dibekukan ada di
  `testdata/parity/v1/`.
- **Scoreboard** (`apps/scoreboard`) adalah PWA terpisah untuk mencatat skor di
  lapangan; tidak berbagi kode dengan `apps/web` selain aturan validasi skor.

## 2. Kontrak & database

- **75 operasi** di kontrak: `packages/contracts/openapi/CONTRACT.sha256`
  (`operations 75`), hasil generate di `apps/api/src/routes_gen.nim`.
  Sumber tangan: `core.yaml` + `community.yaml`; hasil generate: `api.yaml`,
  `routes_gen.nim`, `packages/web-client/src/api.ts`.
- Setiap operasi punya handler (gagal kompilasi bila tidak) dan baris otorisasi di
  `testdata/authz/matrix.yaml`; `./task contract-check` menjaga fingerprint.
- **16 migrasi** di `db/migrations/` (`0001`–`0016`, terakhir
  `0016_cutover_probe.sql`); seed: `db/seeds/platform_config.sql`,
  `db/seeds/achievement_definitions.sql`.
- **36 key config** di `modules/platform/config/registry.nim`, nilai awal di seed;
  override per komunitas di `community.settings` hanya boleh mempersempit platform.
- Nama database: produksi `bm2` (arsip v1 `bm` read-only), lokal `bm2_dev`,
  `bm2_ops`, `bm2_e2e`, `bm2_parity_v2`; cutover memakai `bm_staging`.

## 3. Frontend

Semua rute di `apps/web/src/routes.manifest.ts` punya halaman nyata; tidak ada
`PlaceholderPage` tersisa.

- Login OIDC + shell komunitas (`/`, `/c/:slug`), pemilih komunitas, i18n.
- **Sesi**: daftar, detail, dan panel host/admin untuk lock/unlock, share link,
  skor per game, skip, absent, swap (`apps/web/src/sessions/SessionAdmin.tsx`).
  Panel hanya tampil untuk `host`/`admin`.
- **Share publik** `/s/:code`: sesi, skor, klasemen, dan papan poin penonton.
- **Pemain**: daftar, detail, pengajuan/pelepasan klaim, antrean keputusan admin,
  merge, unlink.
- **Peringkat**: papan + filter tier, detail pemain + badge.
- **Turnamen**: daftar, wizard/editor classic dan team, alat admin rating
  (finalize/ingest/revert/hapus).
- **Ekspor**: post 1080×1350 dan story 1080×1920 dari sesi atau turnamen.
- **Settings komunitas**: anggota, peran, undangan, join request, override config.
- **Owner**: `/owner/communities` untuk membuat komunitas dan melihat yang diikuti.

Frontend memakai `fetch` + hook per fitur. `@tanstack/react-query` masih terpasang
tetapi tidak diimpor; tidak ada service worker di `apps/web` (hanya
`public/manifest.json`).

## 4. Realtime

- WebSocket, bukan SSE. Tiket sekali pakai lewat `POST …/ws-ticket`, lalu upgrade
  ke `/ws/c/{slug}/sessions/{id}` atau `/ws/share/{code}`.
- Frame `session.changed` hanya membawa `seq`; klien harus membaca ulang state.
- Hub fan-out in-memory per proses → **API harus satu instance**. `platform.outbox`
  sudah ada dan dibersihkan janitor, tetapi belum ada produsen event.
- **Klien web belum memakai WebSocket**: halaman sesi memuat state saat dibuka dan
  setelah aksi lokal, bukan saat host lain mengubah.

## 5. Gate

| Suite | Perintah | Catatan |
|---|---|---|
| Format, `nim check`, archcheck, unit | `./task check` | tanpa database |
| Unit + integration | `./task test` | butuh `MAJADU_PG_DSN` |
| Satu modul | `./task verify <modul\|api>` | integration bila DB ada |
| Kontrak | `./task contract-check` | fingerprint + hasil generate |
| Parity | `./task parity verify` / `./task parity v2 verify` | v1 beku 71 kasus/48 rute; v2 142 kasus |
| Coverage | `./task coverage` | per modul, ratchet terhadap `coverage-baseline.json` (59,76% total, diukur dengan integration) |
| Keamanan | bagian dari `./task test` | IDOR, eskalasi, CSRF, replay OIDC, rate limit, klaim |
| Web | `pnpm check:web` | TypeScript, ESLint, Tailwind guard, Vitest |
| E2E | `./task e2e` | Playwright: a11y, visual, compatibility |

E2E berjalan di dua perangkat: **iPhone 17** (WebKit, 402×874, DPR 3) dan
**POCO F5** (Chromium, 393×873, DPR 2.75), `maxDiffPixels: 0`.

## 6. CI

- `.github/workflows/ci.yml` — 7 job: `api-check`, `api-test` (Postgres 18.6),
  `contract`, `web`, `e2e`, `image`, lalu `gate`.
- `.github/workflows/coverage.yml` — instrumented build + ratchet, workflow
  terpisah supaya cache tidak bercampur dengan gate cepat.
- `.github/workflows/nightly.yml` — `./task ci` penuh dengan database service.
- `.github/workflows/release.yml` — dipicu tag `v*`, membangun image sekali dan
  menulis digest ke GitHub Release.
- Semua job `timeout-minutes: 15`, memakai cache, dan tidak menginterpolasi
  konteks GitHub langsung ke shell.

## 7. Infrastruktur

- **Deploy** (`ops/scripts/deploy-vps.sh`): hanya `refs/heads/main`; `flock`;
  `git fetch` + `reset --hard`; pull image **by digest**; rotasi `:local` → `:prev`;
  restart unit; gate `/readyz`; rollback ke `:prev` bila gagal. **Cutover gate:**
  selama env produksi masih menunjuk `bm`, script berhenti sebelum pull/restart.
- **Cutover** (`ops/scripts/cutover.sh`): 12 langkah bernama dengan penanda resume
  (`--from`), `:v1-final` ditag sebelum v1 dihentikan, maintenance Caddy, dump →
  `bm_staging`, peran + migrasi + seed + owner, ETL + verify, `cutover_state`,
  tukar env, tukar snippet Caddy, `/readyz`, smoke. Rollback: `rollback.sh`.
- **Unit**: `ops/systemd/majadu-api.container` (rootless, `Pull=never`,
  `MemoryMax=512M`, `StartLimit*`, `OnFailure=majadu-alert@%n.service`,
  `NoNewPrivileges`, `DropCapability=ALL`) + `majadu-alert@.service`.
- **Caddy**: `api.qouver.com` adalah satu site dengan banyak `handle`; snippet
  majadu adalah **handler block** yang diimpor di dalam site itu, prefix `/majadu`
  dipertahankan. Langkah sekali-jalan ada di `ops/caddy/Caddyfile.api.qouver.com`.
- **Backup/restore/smoke**: `ops/scripts/{backup,restore,smoke}.sh`; dump diverifikasi
  dengan `pg_restore --list` sebelum dipindah, file mode 600.
- **Rehearsal**: `tools/rehearsal/` + `./task rehearsal check`; `timings.json` masih
  `not_run` karena butuh Podman + jendela maintenance di VPS.
- **Artefak** yang belum terbukti di VPS: `caddy validate` pada Caddyfile produksi,
  parsing Quadlet, `podman pull` digest, dan rollback ber-stopwatch. Lihat
  [`../ops/cutover.md`](../ops/cutover.md) §"belum terbukti".

## 8. Sisa pekerjaan

Rencana 88 task: lihat [`roadmap.md`](roadmap.md). Ringkasnya:

- **Operasional, menunggu VPS/waktu:** rehearsal T-063 (dan karenanya bukti
  T-060/061/065), soak T-074, penghapusan `:v1-final` setelah 30 hari (T-082),
  force-push T-108 yang ditunda atas keputusan pemilik.
- **Celah di luar rencana:** klien WebSocket di FE, produsen `platform.outbox`,
  generator jadwal sesi, pembatasan peran turnamen di manifest, dependency
  `@tanstack/react-query` yang mati, dan kenaikan coverage di `modules/account`
  (41,5%), `modules/share` (0%), `modules/tournament` (56,3%).
