# Current Status

Terakhir diperbarui: **2026-11-05**. Dokumen ini menjawab "apa yang benar-benar
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
- **22 migrasi** di `db/migrations/` (`0001`–`0022`, terakhir
  `0022_rank_streak_ladder.sql`); seed: `db/seeds/platform_config.sql`,
  `db/seeds/achievement_definitions.sql`.
- **36 key config** di `modules/platform/config/registry.nim`, nilai awal di seed;
  override per komunitas di `community.settings` hanya boleh mempersempit platform.
- Nama database: produksi `bm2` (arsip v1 `bm` read-only), lokal `bm2_dev`,
  `bm2_ops`, `bm2_e2e`, `bm2_parity_v2`; cutover memakai `bm_staging`.

## 3. Frontend

Frontend v1 dipulihkan penuh di `apps/web/src/legacy/` (tree pra-rewrite) di atas
API v2. Semua rute lama tetap ada, kini ber-prefix `/c/:slug`. Lapisan data lama
(`legacy/queries/endpoints.ts`) menjadi adapter: `CloudSnapshot` dirakit dari
`GET /sessions/{id}`, tulis granular memakai endpoint v2, dan path admin lama
diterjemahkan di `legacy/queries/admin.ts`.

- Login OIDC + shell komunitas (`/`, `/c/:slug`), pemilih komunitas, i18n.
- **Sesi**: daftar, live session (`/c/:slug/s/:id`), scoreboard, wizard 4 langkah
  + generator 5 fase, share code v2 (`/s/:code` untuk publik).
- **Pemain**: roster v2 (klaim, merge, alias, edit, tier, hapus) di
  `/c/:slug/players`; halaman admin pemain lama sudah dipensiunkan dan
  `/admin/players` dialihkan ke roster.
- **Peringkat**: papan + filter tier, detail pemain + badge + riwayat match.
- **Turnamen**: daftar, editor classic dan team, klasemen/bracket, admin rating.
- **Post**: editor Instagram Post (post dan story) dari sesi atau turnamen.
- **Settings komunitas**: anggota, peran, undangan, join request, override config.
- **Owner**: `/owner/communities` untuk membuat komunitas dan melihat yang diikuti.

State klien memakai Zustand (wizard) dan TanStack Query (data server). Service
worker/PWA dipulihkan lewat `vite-plugin-pwa` (install/update banner lama hidup
lagi). Kode v2-only yang tidak ada di v1 (Settings, roster/klaim pemain, owner
communities) tetap dipakai; halaman v2 yang tidak pernah dipasang di router
(home, sessions, rankings, tournaments, export) sudah dihapus.

## 4. Realtime

- WebSocket, bukan SSE. Tiket sekali pakai lewat `POST …/ws-ticket`, lalu upgrade
  ke `/ws/c/{slug}/sessions/{id}` atau `/ws/share/{code}`.
- Frame `session.changed` hanya membawa `seq`; klien harus membaca ulang state.
- Hub fan-out in-memory per proses → **API harus satu instance**. `platform.outbox`
  sudah ada dan dibersihkan janitor, tetapi belum ada produsen event.
- **Klien web belum memakai WebSocket**: halaman sesi memuat state saat dibuka,
  setelah aksi lokal, dan polling 5 detik selama tab terbuka. Hook realtime lama
  (SSE) sudah dinonaktifkan; upgrade ke WS belum dikerjakan.

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
- **Celah di luar rencana:** klien WebSocket di FE (masih polling 5 detik),
  produsen `platform.outbox`, tautan share v1 `/s/{sessionId}` tidak lagi valid
  karena v2 memakai kode acak, dan kenaikan coverage di `modules/account`,
  `modules/share`, `modules/tournament`.
- **Selisih data yang diketahui:** Salma, Youri, Zaid, dan Firda berbeda dari
  `bm.rank_snapshots` v1 karena ledger v1 untuk sesi 2026-10-31 di-ingest
  sebelum sesi itu diedit (100 dari 104 pemain tetap persis sama).
