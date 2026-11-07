# Current Status

Terakhir diperbarui: **2026-11-06**. Dokumen ini menjawab "apa yang benar-benar
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
- **30 migrasi** di `db/migrations/` (`0001`–`0030`, terakhir
  `0030_scoring_grants.sql`); seed: `db/seeds/platform_config.sql`,
  `db/seeds/achievement_definitions.sql`.
- **34 key config** di `modules/platform/config/registry.nim`, nilai awal di seed;
  override per komunitas di `community.settings` hanya boleh mempersempit platform.
- **Format skor per sesi** (ADR-012 di [`../DECISIONS.md`](../DECISIONS.md)): satu
  slot jadwal adalah satu match berisi 1..N set. `0029_scoring_presets.sql`
  menambah `session.game_sets` (satu baris per set), view `session.game_results`,
  serta snapshot `scoring_preset` + `scoring_rules` di `session.sessions`; daftar
  preset ada di config `session.scoring_presets` (MAJADU 30, Classic BO3 21, New
  BWF BO3 15) dan default komunitas di `session.default_scoring_preset`. Sesi v1
  mendapat snapshot `legacy_v1` bertarget 30; kolom `score_a`/`score_b` lama
  dipertahankan sebagai sumber backfill dan jalur rollback. `0030_scoring_grants.sql`
  memberi role aplikasi akses ke tabel dan view baru.
- Nama database: produksi `bm2` (arsip v1 `bm` read-only), lokal `bm2_dev`,
  `bm2_ops`, `bm2_e2e`, `bm2_parity_v2`; cutover memakai `bm_staging`.

## 3. Frontend

Frontend v1 dipulihkan penuh di `apps/web/src/legacy/` (tree pra-rewrite) di atas
API v2. Semua rute lama tetap ada, kini ber-prefix `/c/:slug`. Lapisan data lama
(`legacy/queries/endpoints.ts`) menjadi adapter: `CloudSnapshot` dirakit dari
`GET /sessions/{id}`, tulis granular memakai endpoint v2, dan path admin lama
diterjemahkan di `legacy/queries/admin.ts`.

- Login OIDC + shell komunitas (`/`, `/c/:slug`), pemilih komunitas, i18n.
- **Sesi**: daftar berhalaman (filter dan `load more` dari server), live session
  (`/c/:slug/s/:id`), scoreboard, wizard 4 langkah + generator 5 fase, aksi
  "Finish session" di ringkasan (lock → ingest rating, buka lagi → revert),
  share code v2 (`/s/:code` untuk publik, tab Games/Standings seperti layar sesi
  di aplikasi, memperbarui tiap 10 detik).
- **Pemain**: roster v2 (klaim, merge, alias, edit, tier, hapus) di
  `/c/:slug/players`; halaman admin pemain lama sudah dipensiunkan dan
  `/admin/players` dialihkan ke roster.
- **Peringkat**: papan + filter tier, detail pemain + badge + riwayat match.
- **Turnamen**: daftar, editor classic dan team, klasemen/bracket, admin rating.
- **Post**: editor Instagram Post (post dan story) dari sesi atau turnamen.
- **Settings komunitas**: anggota, peran, undangan, join request, override config.
  Undangan punya halamannya sendiri, `/invites/:token` (di luar shell komunitas);
  login juga langsung meng-claim undangan yang tertuju ke alamat itu, dan
  menerima ulang token yang sama oleh pemiliknya mengembalikan membership yang
  sudah diberikan.
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
  sudah ada dan dibersihkan janitor, tetapi belum ada produsen event. Ini batasan
  yang disengaja: satu container per VPS, jadi fan-out antar-instance belum
  dibutuhkan. Menjalankan dua replika tanpa produsen outbox akan membuat sebagian
  penonton tidak menerima `session.changed`.
- **Klien web memakai WebSocket**: `useSessionRealtime` meminta tiket sekali pakai,
  membuka `/ws/c/{slug}/sessions/{id}`, dan meng-invalidate `['session', id]` setiap
  `session.changed`; frame `full`/`revoked` menghentikan reconnect. Selama socket
  belum tersambung (atau setelah putus) halaman tetap polling 5 detik, jadi
  realtime adalah percepatan, bukan syarat. Di dev, Vite mem-proxy `/ws`; di
  produksi socket memakai origin API (`VITE_WS_BASE`), karena rewrite Vercel tidak
  membawa upgrade.

## 5. Gate

| Suite | Perintah | Catatan |
|---|---|---|
| `nim check`, archcheck, unit | `./task check` | tanpa database |
| Unit + integration | `./task test` | butuh `MAJADU_PG_DSN` |
| Satu modul | `./task verify <modul\|api>` | integration bila DB ada |
| Kontrak | `./task contract-check` | fingerprint + hasil generate |
| Parity | `./task parity verify` / `./task parity v2 verify` | v1 beku 71 kasus/48 rute; v2 143 kasus |
| Ladder turnamen | `./task levels` | baca/tulis `rating.levels`; tanpa baris = rumus per-game |
| Coverage | `./task coverage` | per modul, ratchet terhadap `coverage-baseline.json` (39,14% total, integration; gcov dibaca per binary, toleransi 0,1 pp untuk derau gcov, ~7 menit) |
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
  `git fetch` + `reset --hard`; pull image **by digest**; **`dbtools migrate` +
  `dbtools verify` dari digest itu sebelum rotasi tag** (gagal = rilis batal,
  `:local`/`:prev` tak tersentuh; revisi skema dicatat di `last-release.json`);
  rotasi `:local` → `:prev`; restart unit; gate `/readyz`; rollback ke `:prev`
  bila gagal. Skema tidak ikut di-rollback, jadi migrasi wajib expand/contract.
  **Cutover gate:** selama env produksi masih menunjuk `bm`, script berhenti
  sebelum pull/restart.
- **Cutover** (`ops/scripts/cutover.sh`): 14 langkah bernama dengan penanda resume
  (`--from`), `:v1-final` ditag sebelum v1 dihentikan, maintenance Caddy, dump →
  `bm_staging`, peran + migrasi + seed + owner, ETL + verify, `cutover_state`,
  tukar env, tukar snippet Caddy, `/readyz`, smoke. Rollback: `rollback.sh`.
- **Unit**: `ops/systemd/majadu-api.container` (rootless, `Pull=never`,
  `MemoryMax=512M`, `StartLimit*`, `OnFailure=majadu-alert@%n.service`,
  `NoNewPrivileges`, `DropCapability=ALL`) + `majadu-alert@.service`.
- **Snapshot harian**: `majadu-snapshot.service` + `.timer` menjalankan
  `ranksnapshot` dari image yang sama (`podman run --rm --pull=never`), supaya
  panah pergerakan punya snapshot baru tiap hari. Diaktifkan setelah cutover.
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
- **Celah di luar rencana:** produsen `platform.outbox` (realtime masih
  per-proses). Coverage sudah diukur ulang dengan harness yang benar (gcov
  dibaca setelah setiap binary; sebelumnya `.gcda` basi membuat modul yang
  teruji dilaporkan 0%), jadi baseline 39,14% adalah angka pertama yang bisa
  dipercaya — bukan penurunan. Modul terendah: `apps/api` 15,47% dan `tools`
  21,02%.
- **Selisih data yang diketahui (diterima):** Salma, Youri, Zaid, dan Firda
  berbeda dari `bm.rank_snapshots` v1 karena ledger v1 untuk sesi 2026-10-31
  di-ingest sebelum sesi itu diedit. Keputusan pemilik: v2 mengikuti data
  terkini, bukan ledger v1 yang basi; 100 dari 104 pemain tetap persis sama.
