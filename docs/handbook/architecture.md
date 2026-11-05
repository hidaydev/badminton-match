# Architecture

Dokumen ini menggambarkan **runtime v2**: backend Nim + frontend React yang ada di repo
hari ini. Backend Go v1 sudah dihapus dari tree (T-082); asal-usul semantik yang
diport ditandai di docstring modul dan dijelaskan di §12.

## 1. Bentuk sistem

```text
Browser (React 19 SPA)
   │  same-origin /api  (dev: Vite proxy · prod: Vercel rewrite)
   ▼
apps/api (Nim 2.4, Mummy HTTP + WebSocket)
   │  SQL langsung (db_connector, pool)
   ▼
PostgreSQL 18 — database bm2, skema per domain
```

- Frontend: React 19, Vite 8, Tailwind 4, React Router 7 (`apps/web/package.json`).
- Backend: Nim `>= 2.4.0 & < 2.5.0`, Mummy 0.4.8, `db_connector` (commit pin), nimcrypto
  (`majadu.nimble`, `deps.lock`).
- Database: PostgreSQL 18; tooling memakai nama database `bm2_dev` / `bm2_e2e`
  (`.github/workflows/ci.yml`, `task.d/e2e.sh`). Skema dan tabel di
  [`data-model.md`](data-model.md).

Tidak ada PostgREST, Supabase, SSE, service worker, atau store global (Zustand) di v2.

## 2. Peta repo

| Path | Isi |
|---|---|
| `apps/api/src/` | entrypoint, router, auth, realtime, config route |
| `apps/api/tests/` | test HTTP + kontrak (unit; integration di `tests/integration/`) |
| `modules/` | domain + infrastructure per bounded context |
| `shared/platform-lib/` | logger, clock, sha256, uuidv7, metrics, build info |
| `apps/web/src/` | shell React, halaman, klien API per fitur |
| `packages/contracts/openapi/` | dua spec sumber + dokumen gabungan + fingerprint |
| `packages/web-client/src/api.ts` | klien TypeScript hasil generate |
| `db/migrations/`, `db/seeds/` | skema (`0001`–`0016`) dan seed konfigurasi |
| `tools/` | dbtools, contract-gen, parity, CLI ops, OIDC stub |
| `e2e/` | suite Playwright (a11y, visual, kompatibilitas) |
| `task`, `task.d/` | satu-satunya command runner (`./task <target>`) |

Sumber: `config.nims:1-8` (path modul), `task:13-34` (daftar target),
`packages/contracts/openapi/README.md`.

## 3. Boot & konfigurasi proses

Entrypoint: `apps/api/src/main.nim`.

1. `loadConfig()` mewajibkan `MAJADU_PORT` dan `MAJADU_DRAIN_MS`; `MAJADU_SHUTDOWN_TIMEOUT_MS`
   default 30 dtk (`apps/api/src/server.nim:29-42`).
2. `bootHandler` mewajibkan `MAJADU_PG_DSN`, memuat konfigurasi OIDC, keyring share code
   (`SHARE_CODE_KEYS`, `SHARE_CODE_ACTIVE_KEY_ID`), lalu registry config dari database
   (`apps/api/src/main.nim:34-47`). Nilai yang hilang membuat proses menolak start, bukan
   menyajikan 500.
3. `newApp()` + `install()` menyimpan satu `App` process-wide; handler Mummy memakai
   cast `gcsafe` satu-satunya di boundary (`apps/api/src/app.nim:2303-2320`).
4. Server berjalan dengan `max(countProcessors(), 2)` worker thread; SIGTERM/SIGINT
   memicu drain lalu tutup (`apps/api/src/main.nim:49-74`).

Konfigurasi bisnis **tidak** dibaca dari env. Semua angka ada di `platform.config`
dengan registry bertipe di `modules/platform/config/registry.nim`; snapshot di-cache per
`platform.config_version`; saat nilainya berubah cache memuat ulang tanpa restart
(`modules/platform/config/store.nim:15-80`).

## 4. Pipeline request

`proc route` (`apps/api/src/app.nim:1906`) menjalankan urutan tetap:

1. **Body limit** — `security.max_body_bytes` (`apps/api/src/app.nim:1911`).
2. **CSRF** — method state-changing wajib origin yang diizinkan (atau `Sec-Fetch-Site`
   `same-origin`/`none`); request ber-cookie tanpa Origin ditolak
   (`apps/api/src/security_headers.nim:22-45`).
3. **Rate limit** — bucket per template route + alamat klien; `/s/{code}` punya ceiling
   tambahan per kode (`apps/api/src/app.nim:1917-1938`).
4. **Rute sistem** — `/healthz`, `/readyz` (query `select 1`), `/version`, `/ops/*`
   (`apps/api/src/app.nim:1940-1958`).
5. **Client lama** — `X-API-Version` di bawah versi server dijawab `410 CLIENT_OUTDATED`
   (`apps/api/src/app.nim:1890-1904`, `apps/api/src/app.nim:1960`).
6. **Auth + otorisasi** — cookie sesi `majadu_session` (HttpOnly, SameSite=Lax) →
   `currentUser` → `loadCommunity` → `gate` (`apps/api/src/app.nim:168-207`,
   `apps/api/src/community_context.nim:15-30`, `apps/api/src/auth_middleware.nim:19-42`).
7. **Dispatch** — cabang per prefix: `/c/{slug}/players`, `/sessions`, `/tournaments`,
   `/ratings`, `/members`, `/settings`, `/ws/...`, `/s/...`.

Semua respons melewati `send()` sehingga header keamanan tidak bisa terlewat
(`apps/api/src/app.nim:110-120`, `apps/api/src/security_headers.nim:62-75`). Error memakai envelope
`{"status", "code", "detail"}` (`apps/api/src/app.nim:129-130`). Log JSON meredaksi share code,
ticket, cookie, email, dan IPv4 (`shared/platform-lib/logger.nim:11-32`).

### Peran & batas data

- `member` boleh membaca; `host`/`admin` boleh menulis data operasional; `admin`
  mengelola anggota, settings, rating, dan klaim.
- `platformOwner` hanya melewati rute manajemen platform (buat komunitas); di dalam
  komunitas, role membership tetap menentukan (`modules/account/domain/roles.nim:43-61`).
- Slug komunitas asing dan non-anggota sama-sama `404` supaya keberadaan komunitas tidak
  bocor (`apps/api/src/community_context.nim:15-22`).
- Setiap query data komunitas membawa `community_id`; tidak ada jalur lintas komunitas.

Matriks otoritatif per operasi: `testdata/authz/matrix.yaml` (dibuat dari kontrak dan
diuji oleh `apps/api/tests/`).

## 5. Kontrak API & codegen

Kontrak ditulis tangan di dua dokumen JSON-syntax:

- `packages/contracts/openapi/core.yaml`
- `packages/contracts/openapi/community.yaml`

`tools/contract-gen` menggabungkannya menjadi `api.yaml`, menghasilkan
`apps/api/src/routes_gen.nim` + `packages/web-client/src/api.ts`, dan menulis
`CONTRACT.sha256`. Jumlah operasi saat ini **75** (`CONTRACT.sha256`, baris
`operations 75`). `./task contract-check` gagal bila spec, hasil generate, atau
fingerprint berbeda.

Kontrak bukan dokumentasi pasif: `verifyHandlers` gagal saat kompilasi bila satu
operation tidak punya handler (`verifyHandlers` di `apps/api/src/routes_gen.nim`), dan `apps/api/tests/routes_test.nim`
mengunci jumlah operasi.

Rute implementasi yang **tidak** ada di kontrak (sengaja tidak dipromosikan):
`GET /ops/ping` (bearer token ops, `apps/api/src/app.nim:1943-1946`) dan
`DELETE /c/{slug}/rating-sources/{id}` (admin, dipakai pembersihan sumber rating).
Anggap keduanya internal; klien publik memakai operasi di kontrak.

## 6. Modul & aturan lapisan

```text
modules/
├── account/       # role, audit, lifecycle, OIDC, sesi login, ops token
├── achievement/   # katalog badge + backfill
├── community/     # membership, invite, join request, settings
├── platform/      # registry config, idempotency, janitor, audit retention
├── player/        # domain pemain, klaim, merge, store
├── rating/        # rumus poin, ingest/revert/rebuild, baca papan
├── session/       # tulis sesi, schedule, swap, standings
├── share/         # enkripsi kode share + lookup
└── tournament/    # domain classic/team, draw, store
```

- `domain/` tidak menyentuh database atau env; `infrastructure/` memiliki SQL dan
  adapter.
- `tools/archcheck` menolak akses tabel domain dari lapisan yang salah dan pembacaan env
  di luar edge proses (`tools/archcheck/rules.nim:1-10`); `./task check` menjalankannya.
- Dependency antar modul mengalir lewat domain/store, bukan lewat handler HTTP.

## 7. Database

Database `bm2`, dipisah per skema: `platform`, `community`, `player`, `session`,
`tournament`, `rating`, `achievement`, `auth`, `account` (ditambah ledger `dbtools`).
Semua tabel anak memakai FK komposit `(community_id, id)` sehingga satu baris tidak bisa
menyeberang komunitas.

Migrasi dijalankan `tools/dbtools` dengan checksum dan ledger
(`tools/dbtools/main.nim:6-16`); `./task bootstrap` menjalankan migrasi, seed, owner
pertama, dan komunitas default. Detail tabel ada di [`data-model.md`](data-model.md).

## 8. Realtime (WebSocket, bukan SSE)

- Klien meminta **ticket sekali pakai**: `POST /c/{slug}/sessions/{id}/ws-ticket` atau
  `POST /s/{code}/ws-ticket`. Ticket disimpan sebagai hash, kedaluwarsa
  `ws.ticket_ttl_seconds`, dan dihapus saat dipakai (`apps/api/src/ws_ticket.nim:35-60`,
  `apps/api/src/app.nim:557-588`).
- Upgrade: `GET /ws/c/{slug}/sessions/{id}` atau `GET /ws/share/{code}`. Origin diperiksa
  lebih dulu; URL komunitas harus cocok dengan ticket (`apps/api/src/app.nim:1676-1710`).
- Hub fan-out **in-memory per proses** dengan cap per sesi, per IP, dan per proses dari
  registry (`apps/api/src/live.nim:53-101`).
- Frame yang dikirim server: `{"type":"ready"}`, `{"type":"session.changed","seq":N}`,
  `{"type":"full"}` saat kapasitas penuh, `{"type":"revoked"}`, `{"type":"pong"}`.
  `seq` hanya penanda gap — **tidak ada replay**; klien yang butuh state penuh membaca
  ulang `GET /session` (`apps/api/src/live.nim:33-36`, `apps/api/src/live.nim:142-145`).
- Klien boleh mengirim `ping`; `subscribe` diterima tetapi tidak menyimpan state
  (`apps/api/src/live.nim:166-194`).

Karena hub in-memory, API harus berjalan satu instance. Ini batasan yang disengaja,
bukan fitur multi-node.

## 9. Alur tulis sesi

Semua mutasi jadwal memakai **optimistic concurrency di level sesi**:

1. Klien mengirim `If-Match: "<version>"`; tanpa header → `428`
   (`apps/api/src/app.nim:584-599`).
2. Handler memanggil modul `session`; `UPDATE ... WHERE version = $n` menaikkan
   `session.sessions.version` dalam transaksi yang sama
   (`modules/session/write.nim:63-82`, `modules/session/schedule.nim:190-216`).
3. Versi tidak cocok → `412 STALE_VERSION`; sesi tidak ada → `404`.
4. Setelah commit, hub menyiarkan `session.changed` dengan versi baru
   (`apps/api/src/app.nim:641`, `apps/api/src/app.nim:678`, `apps/api/src/app.nim:711`).
5. Mutasi yang menyediakan `Idempotency-Key` menyimpan respons di
   `platform.idempotency_keys`; replay dengan body sama mengembalikan respons lama,
   body berbeda → `409 IDEMPOTENCY_CONFLICT` (`modules/platform/idempotency.nim:23-52`,
   `apps/api/src/app.nim:599-617`).

Jadwal disimpan relasional di `session.games` (bukan JSON snapshot): satu baris per
`round_no`/`court_no`, dengan hingga dua pemain per sisi. `PUT .../schedule` hanya
menyentuh game yang disebut, sehingga jadwal parsial tetap valid
(`modules/session/schedule.nim:114-160`). Lock sesi mencatat `approved_at`/`approved_by`
(`db/migrations/0006_session_approval.sql`).

## 10. Rating & achievement

- Poin dihitung **saat baca** dengan aturan v1: satu entri per pemain per sumber
  (sesi = jumlah semua game; turnamen = `champion_points × round_ratio` bila kind
  punya baris `rating.levels` yang aktif), lalu `best_n` entri terbaik dalam window
  `window_weeks` dijumlahkan dan dibulatkan sekali (`modules/rating/projection.nim`).
- Nilai satu game = `base * (0.5 + 0.5 * clamp(margin/target, -1, 1))`; pengali lawan =
  `clamp(rata-rata tier lawan / rata-rata populasi, low, high)`, dengan kekuatan tier =
  titik tengah band (`modules/rating/domain/rating.nim`).
- Satu game butuh pemain hadir di kedua sisi; pemain `absent` tidak dihitung dan
  `session.game_skips` mengeluarkan pemain dari game itu saja. Papan dijangkar pada
  `local_date` event terakhir, bukan hari ini (`modules/rating/read.nim`).
- `rating.deltas` tetap disimpan sebagai ledger integer per game untuk bookkeeping dan
  riwayat pemain; angka papan tidak dibaca dari delta.
- Semua parameter berasal dari registry: `rating.session_base`, `rating.score_target`,
  `rating.opponent_clamp`, `rating.window_weeks`, `rating.best_n`,
  `rating.thin_evidence_n`, `rating.tier_bands` (`modules/rating/infrastructure/params.nim:5-27`).
- Ingest idempoten per sumber (sesi/turnamen): run kedua tidak menambah event/delta
  (`modules/rating/infrastructure/ingest.nim:146-171`). Sign-off sumber disimpan di
  `rating.sources`; `DELETE …/rating` menolak sumber yang finalized dan rebuild penuh
  tidak mengubah baris sumber (`db/migrations/0013_rating_sources.sql`).
- Badge dihitung dari fakta agregat dan katalog `achievement.definitions`; key yang tidak
  ada di seed tidak mungkin diterima (`modules/achievement/domain/achievement.nim:65-100`,
  `db/seeds/achievement_definitions.sql`).

## 11. Frontend shell

- `apps/web/src/main.tsx` membuat root; `App.tsx` memasang `AuthProvider` →
  `BrowserRouter` → `CommunityProvider` → shell. `AppNav` hanya tampil setelah login
  (`apps/web/src/App.tsx`).
- Rute adalah daftar data di `apps/web/src/routes.manifest.ts`; setiap entri
  menentukan `requiresAuth`, `roles`, `platformOwner`, dan `navGroup`. `visibleNav`
  menyaring menu berdasarkan role komunitas yang sedang dipilih.
- Login memakai OIDC lewat API; token tidak pernah masuk JavaScript. Semua panggilan
  memakai cookie sesi (`credentials: 'include'`) dan header `X-API-Version: 2`
  (`apps/web/src/auth/api.ts`).
- Browser tidak memanggil domain API langsung: dev memakai proxy `/api` di
  `vite.config.ts`, produksi memakai rewrite Vercel (`apps/web/vercel.json`).
- Data fetching per fitur memakai `useEffect` + `useState` dengan request key (mis.
  `useRankings`, `useSession`, `useCommunityConfig`), bukan cache global. Dependency
  `@tanstack/react-query` masih terpasang tetapi tidak diimpor kode.
- Semua teks UI ada di `apps/web/src/i18n/en.ts`; test menolak teks JSX hardcoded
  (`apps/web/README.md`).

## 12. v1 (Go) yang sudah dihapus

Sumber Go v1 (`apps/api/cmd/`, `apps/api/internal/`, `apps/api/api/`, `go.mod`,
`go.sum`, `Makefile`) dihapus di T-082, setelah image
`localhost/majadu-api:v1-final` dipertahankan sebagai jalur rollback. Konsekuensinya
v1 tidak bisa di-hotfix dari source selama masa simpan image; source-nya hanya ada di
riwayat git. Kontrak v1 yang dibekukan tinggal di `testdata/parity/v1/` (kasus,
`cases.tsv`, dan `routes.txt`) dan tidak butuh source Go.

Docstring modul yang menyebut `*.go` adalah catatan asal semantik ("ported from"),
bukan file yang masih ada di tree. `ops/` sudah memakai env v2 (`MAJADU_PG_DSN` dan
kawan-kawan di §3); prefix `/majadu` dipertahankan setelah cutover, jadi itu bukan
sisa v1.

## 13. Testing & gate

| Gate | Isi | Butuh DB |
|---|---|---|
| `./task check` | `nim check`, unit test, archcheck | tidak |
| `./task test` | unit + integration (`INTEGRATION=1`) | ya (`MAJADU_PG_DSN`) |
| `./task verify <modul\\|api>` | test satu modul | bila ada integration |
| `./task contract-check` | fingerprint + hasil generate | tidak |
| `./task coverage` | baris per modul, ratchet baseline | ya (integration) |
| `./task parity verify` | korpus v1 beku + v2 | tidak / v2: ya |
| `pnpm check:web` | TypeScript, ESLint, Tailwind, Vitest | tidak |
| `./task e2e` | Playwright: a11y, visual, kompatibilitas | ya (DB `bm2_e2e`) |

CI menjalankan job `api-check`, `api-test` (Postgres 18.6 service), `contract`, `web`,
`e2e`, `image`, lalu `gate` yang menuntut semua job sukses
(`.github/workflows/ci.yml`). Coverage punya workflow sendiri
(`.github/workflows/coverage.yml`) supaya build terinstrumentasi tidak berbagi cache
dengan gate cepat. E2E memakai dua perangkat nyata: `iphone-17` (WebKit, 402×874,
DPR 3) dan `poco-f5` (Chromium, 393×873, DPR 2.75) (`e2e/browsers.ts`).

## 14. Prinsip

1. **Kontrak dulu** — perubahan API dimulai dari spec, lalu generate.
2. **Server authoritative** — validasi skor, poin, otorisasi, dan invariant ada di Nim.
3. **Satu aturan satu tempat** — angka bisnis di registry, bukan duplikat di FE/BE.
4. **Komunitas adalah batas data** — setiap baris dan query membawa `community_id`.
5. **Gagal berisik** — konfigurasi hilang/tipe salah menolak start; error tidak ditelan.
