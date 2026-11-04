# Current Status

Terakhir diperbarui: **2026-11-04** — disinkronkan dengan kode v2 (Nim, kontrak 74
operasi, migrasi `0014`, E2E Playwright).

Pintu masuk tercepat. Setelah ini: [`architecture.md`](architecture.md),
[`data-model.md`](data-model.md), [`features-and-routes.md`](features-and-routes.md).

## 1. Apa yang berjalan di repo ini

```text
apps/web   React 19 · Vite 8 · Tailwind 4 · React Router 7
   │        same-origin /api
apps/api   Nim 2.4 · Mummy (HTTP + WebSocket) · db_connector
   │
Postgres 18 · database bm2 (dev/e2e: bm2_dev / bm2_e2e)
```

- **Backend aktif = Nim** di `apps/api/src/` (`apps/api/Dockerfile` membangun
  `apps/api/src/main.nim`).
- **Kode Go v1 sudah dihapus** di T-082. Rollback memakai image
  `localhost/majadu-api:v1-final` (disimpan 30 hari), bukan source; kontrak v1
  yang dibekukan ada di `testdata/parity/v1/`.
- Alur kerja dokumen ini: branch `main` (branch lama masih ada di lokal/remote, tetapi
  tidak dipakai oleh handbook ini).

## 2. Kontrak & database

- **74 operasi** di kontrak: `packages/contracts/openapi/CONTRACT.sha256:7`,
  `apps/api/src/routes_gen.nim:682`. Sumber tangan: `core.yaml` + `community.yaml`;
  hasil generate: `api.yaml`, `routes_gen.nim`, `packages/web-client/src/api.ts`.
- Setiap operasi punya handler (gagal kompilasi bila tidak:
  `apps/api/src/routes_gen.nim:686-695`) dan baris otorisasi (`testdata/authz/matrix.yaml`).
- **14 migrasi** di `db/migrations/`, terakhir `0014_fix_game_sides.sql`; seed:
  `db/seeds/platform_config.sql`, `db/seeds/achievement_definitions.sql`.
- Skema dipisah per domain: `platform`, `community`, `player`, `session`, `tournament`,
  `rating`, `achievement`, `auth`, `account` — lihat [`data-model.md`](data-model.md).

## 3. Frontend hari ini

Halaman yang sudah nyata (bukan placeholder):

- Login OIDC + shell komunitas (`/`, `/c/:slug`).
- Daftar sesi + detail sesi **baca-saja** (`/c/:slug/sessions`, `…/sessions/:id`) —
  peserta, jadwal, skor, standings.
- Papan poin + detail pemain (`/c/:slug/rankings`, `…/rankings/:playerId`).
- Daftar turnamen, editor classic, editor team, ekspor sosial
  (`/c/:slug/tournaments*`, `/c/:slug/export`).

Masih placeholder (`PlaceholderPage`):

- `/c/:slug/players`
- `/c/:slug/settings`
- `/s/:code` (halaman share publik)
- `/owner/communities`

Belum ada UI untuk: membuat sesi, mengubah skor/swap/absent/lock, share link, dan
pengelolaan anggota/klaim pemain. API-nya sudah ada.

Frontend memakai `fetch` + hook `useEffect`/`useState` per fitur; `@tanstack/react-query`
masih terpasang di `package.json` tetapi tidak diimpor. Tidak ada service worker/Workbox di v2; yang ada hanya
`apps/web/public/manifest.json` (metadata aplikasi).

## 4. Realtime

- WebSocket, bukan SSE. Ticket sekali pakai lewat `POST …/ws-ticket`, lalu upgrade ke
  `/ws/c/{slug}/sessions/{id}` atau `/ws/share/{code}`.
- Frame `session.changed` hanya membawa `seq`; tidak ada replay. Klien harus membaca
  ulang state (`GET /c/{slug}/sessions/{id}`) setelah menerima perubahan.
- Hub fan-out in-memory per proses → **API harus satu instance**.

Detail: [`architecture.md`](architecture.md) §8.

## 5. Testing & gate

| Suite | Command | Catatan |
|---|---|---|
| Unit API + `nim check` + archcheck | `./task check` | tanpa database |
| Unit + integration API | `./task test` | butuh `MAJADU_PG_DSN`; suite integration butuh `INTEGRATION=1` (dipasang `task test`) |
| Satu modul | `./task verify <modul|api>` | integration butuh DB |
| Kontrak | `./task contract-check` | fingerprint + hasil generate |
| Web | `pnpm check:web` | TypeScript, ESLint, Tailwind, Vitest |
| Build web | `pnpm build:web` | Vite production build |
| E2E | `./task e2e` | Playwright, DB `bm2_e2e`, API + OIDC stub + preview |

E2E berjalan di dua perangkat: **iPhone 17** (WebKit, 402×874, DPR 3) dan **POCO F5**
(Chromium, 393×873, DPR 2.75), dengan `maxDiffPixels: 0` (`e2e/browsers.ts:19-38`,
`apps/web/playwright.config.ts`). Rute baseline: home, community, rankings, tournaments, classic editor, sessions,
session, export (`e2e/visual.routes.ts:19-33`).

Angka pass tidak ditulis di sini karena berubah setiap commit; jalankan perintahnya.

## 6. CI

`.github/workflows/ci.yml` menjalankan:

- `api-check` (`./task check`)
- `api-test` (Postgres 18.6 service, `./task dev-db` + `./task test`)
- `contract` (`./task contract-check`)
- `web` (`pnpm install --frozen-lockfile`, `pnpm check:web`, `pnpm build:web`)
- `e2e` (Playwright + `./task deps-check`)
- `image` (`docker build apps/api`)
- `gate` (semua job harus sukses)

`nightly.yml` menjalankan `./task ci` dengan database service.

## 7. Infrastruktur (apa yang benar-benar ada di repo)

- `apps/api/Dockerfile` — multi-stage Nim 2.4.0 → `debian:bookworm-slim`, user uid 10001,
  port 8080.
- `ops/scripts/deploy-vps.sh` — webhook `refs/heads/main` saja, `flock`, build lokal,
  tag `:local`/`:prev`, restart quadlet, healthcheck 30 dtk, rollback ke `:prev`.
- `ops/systemd/majadu-api.container`, `ops/caddy/Caddyfile.api.qouver.com`,
  `ops/env/prod.env.example`, `ops/webhook/webhook.json`.

**Peringatan konsistensi:** artefak `ops/` masih memakai nama v1 — schema `bm`,
`DATABASE_URL`, `MAJADU_DB_SCHEMA`, dan Caddy prefix `/majadu`. Backend Nim membaca
`MAJADU_PG_DSN`, `MAJADU_PORT`, `SHARE_CODE_KEYS`, dan seterusnya
(`apps/api/src/main.nim:34-47`, `apps/api/src/server.nim:29-42`). Jadi `ops/` **belum**
menjadi deployment v2 yang siap pakai; jangan menyalin nilainya sebagai konfigurasi
produksi. Kredensial/alamat asli tidak ada di repo.

## 8. Database

Satu model data v2; tidak ada `bm_dev`/`bm` di dokumen ini. Nama database yang dipakai
tooling: `bm2_dev` (CI/dev) dan `bm2_e2e` (E2E). Untuk produksi, konfigurasi berada di
luar repo.

- Registry config: 36 key, nilai awal di `db/seeds/platform_config.sql`; nilai bisnis
  diubah lewat data, bukan deploy (`modules/platform/config/registry.nim`).
- Papan poin: window 12 minggu, 10 entri terbaik, minimal 3 game; dihitung saat baca.
- Tidak ada mesin Glicko, tabel musim, atau rating absolut.

## 9. Utang yang terlihat dari kode

1. **UI sesi belum bisa menulis** — halaman detail hanya membaca; mutasi skor/swap/lock
   belum punya layar.
2. **Halaman placeholder** — players, settings, share publik, owner communities.
3. **Turnamen dibatasi manifest** ke `host`/`admin`, walau API mengizinkan `member`
   membaca.
4. **Generator jadwal sesi belum ada** di v2; kontrak hanya menyediakan
   `PUT …/schedule` untuk klien yang sudah punya jadwal.
5. **`ops/` masih v1-oriented** (lihat §7).
6. **Kode Go v1 masih di tree** (T-082) dan beberapa dokumen lama masih merujuknya.
7. **`platform.outbox` belum dipakai produsen event**; realtime masih fan-out in-memory.
8. **Klien WebSocket belum ada di FE** — endpoint ticket/upgrade siap, tetapi halaman
   sesi masih memuat state sekali saat dibuka.
9. **`packages/contracts/openapi/README.md` menyebut 73 operasi**, sedangkan kontrak
   aktual 74 (`CONTRACT.sha256:7`).
