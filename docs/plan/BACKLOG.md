# BACKLOG — Majadu v2 (Nim)

Status: draft v3 (setelah review executability, consistency, adversarial)
Tanggal: 2026-11-03
Rujukan: `PRD.md`, `TECH-SPEC.md`, `reviews/`

---

## 0. Protokol paralel

1. **`Owns` setingkat file**, bukan direktori induk. Dua task tidak boleh berbagi file.
2. **`task` adalah dispatcher, bukan file bersama.** `./task` memanggil
   `task.d/<target>.sh`; setiap task menambah **file sendiri** di `task.d/`.
   Setelah T-018, tidak ada task lain yang menyunting `task` atau `config.nims`.
3. **File generated hanya milik generatornya**: `apps/api/src/routes_gen.nim` dan
   `packages/web-client/` hanya oleh T-009. Task lain tidak menyentuhnya.
4. **`App.tsx` disentuh sekali** oleh T-028. Task FE lain hanya menambah halaman dan
   entri di `apps/web/src/routes.manifest.ts` (dibuat T-028 dengan placeholder).
5. **`nimcache` per worktree** disetel `./task` (T-018). Tanpa ini, build paralel
   saling merusak karena Nim mengunci cache per nama file proyek.
6. **DB per worker**: template `bm2_template`, database `bm2_<agent>` (bukan schema);
   nama di luar prefiks `bm2_` ditolak oleh guard.
7. **Migrasi**: satu berkas per task (`0001`–`0005`). Bila satu task melebihi ~350
   baris, pecah menjadi dua berkas bernomor berurutan dan perbarui `Depends`. Nomor
   di luar rentang itu hanya dibuat oleh DB agent pada waktu yang sama.
8. **Kontrak** hanya ditulis T-008a/T-008b dan hanya digerbang T-016. `api.yaml`
   (hasil gabungan), `routes_gen.nim`, dan `packages/web-client/` adalah artefak
   generated — task lain tidak menyentuhnya.
9. **Tidak ada push.** Merge ke `main` lokal oleh orchestrator.

Konkurensi maksimum: **4 agen** (2 backend, 1 FE, 1 platform/infra).

---

## 1. Lane

| Lane | Domain | File utama |
|---|---|---|
| A | Platform | `config.nims`, `task`, `task.d/`, `shared/platform-lib/`, `tools/{dbtools,archcheck,contract-gen,mock-api,parity,fixtures}`, `.github/`, `apps/api/Dockerfile` |
| B | Account | `modules/account/`, `apps/api/src/{auth*,session*}`, `tools/oidc-stub/` |
| C | Session | `modules/session/`, `modules/share/`, `apps/api/src/{session*,live}*` |
| D | Player & Rating | `modules/player/`, `modules/rating/`, `modules/achievement/` |
| E | Tournament | `modules/tournament/`, `apps/web/src/pages/Tournament*` |
| F | Contract & FE | `packages/`, `apps/web/src/{queries,auth,community}/`, `apps/web/src/pages/` |
| G | Ops | `ops/`, `tools/rehearsal/`, `tools/import/` |
| H | Quality | `tools/parity/`, `testdata/`, `e2e/`, `apps/api/tests/` |
| I | Security plumbing | `apps/api/src/{ratelimit,security_headers,community_context}.nim`, `modules/platform/idempotency.nim` |
| J | Config | `modules/platform/config/`, `db/seeds/` |

---

## 2. R0 — Fondasi

| ID | Task | Depends | Owns | Acceptance | Paralel |
|---|---|---|---|---|---|
| T-001 | Skeleton: `config.nims`, entrypoint, server bootstrap | — | `config.nims`, `apps/api/src/main.nim`, `apps/api/src/server.nim` | `nim check apps/api/src/main.nim` polos lulus; binary start dan merespons `/healthz` | tidak |
| T-018 | Task runner: dispatcher + nimcache per worktree | T-001 | `task`, `task.d/check.sh`, `task.d/build.sh`, `task.d/test.sh`, `task.d/README.md` | Target dasar jalan; `--nimcache` unik per worktree terbukti lewat dua worktree | tidak |
| T-002 | Pin toolchain + `deps.lock` + `./task deps-check` | T-018 | `*.nimble`, `deps.lock`, `task.d/deps.sh` | Drift → exit ≠ 0 | tidak |
| T-003 | `platform-lib`: logger (redaksi kode/`ticket`), metrics, clock, uuidv7, errors, **sha256**, **request context** | T-018 | `shared/platform-lib/*.nim` (kecuali `db/`) | Unit test; clock dipaksa `MAJADU_NOW`; sha256 punya vektor uji; log tidak memuat segmen `/s/<kode>` atau `?ticket=` | ya (T-004) |
| T-004 | DB layer: pool **berukuran serverThreads**, binder **PQexecParams** (bind + NULL) | T-003 | `shared/platform-lib/db/*.nim` | Round-trip: parameter bind nyata, NULL tidak jadi `""`, jsonb `?` tidak rusak; pool = threads | ya (T-003) |
| T-007 | Dev DB lokal (PostgreSQL 18.6 yang sudah ada), `bm2_dev` + `bm2_template` + database per worker, guard prefiks | T-018 | `ops/dev/pg-up.sh`, `ops/dev/reset.sh`, `ops/dev/README.md` | `./task dev-db` < 20 s; `createdb -T bm2_template bm2_<agent>` < 1 s; menolak nama non-`bm2_` | ya |
| T-005 | `dbtools`: ledger, checksum, migrate/verify/seed | T-004, T-007 | `tools/dbtools/` | Migrasi dari nol < 20 s; checksum drift → exit ≠ 0 | tidak |
| T-006a | Migrasi inti: community, session, session.links (hash + `code_enc` dengan nonce/tag/AAD), courts, games, players (+`user_id` unique parsial per komunitas) | T-005 | `db/migrations/0001_*.sql` | `dbtools verify` bersih; `community_id` NOT NULL; FK komposit hanya kolom NOT NULL; `UNIQUE(community_id,user_id) WHERE user_id IS NOT NULL` | tidak (blokir 006b–e) |
| T-006b | Migrasi rating & achievement | T-006a | `db/migrations/0002_*.sql` | Idem; relasi opsional dijaga CHECK/trigger, bukan FK komposit | ya (006c) |
| T-006c | Migrasi tournament | T-006a | `db/migrations/0003_*.sql` | Idem | ya |
| T-006d | Migrasi platform/auth: `platform.{community,user,config,config_version,idempotency_keys,import_row_map,ws_ticket,cutover_state}`, `auth.oauth_flows`, `account.sessions`, `account.audit`, `outbox` | T-006a | `db/migrations/0004_*.sql` | Idem | ya |
| T-006e | Migrasi komunitas: `community.{membership,invite,join_request,settings}` | T-006a | `db/migrations/0005_*.sql` | `UNIQUE(community_id,user_id)`; satu pengajuan pending per user+komunitas; peran per keanggotaan; undangan unik | ya |
| T-099 | Generator data sintetis deterministik untuk v1 (tanpa data produksi) | T-007 | `tools/fixtures/` | Seed < 10 s; dua kali jalan → data sama | ya |
| T-014 | Env v1 lokal: restore skema + data sintetis | T-007, T-099 | `ops/dev/v1/` | `./task dev-v1` naik; v1 merespons 48 route | ya |
| T-008a | OpenAPI inti (auth, session, share, player, rating, achievement, tournament) | T-018 | `packages/contracts/openapi/core.yaml` | Spec lint bersih | ya |
| T-008b | OpenAPI komunitas & config (10 operasi) | T-018 | `packages/contracts/openapi/community.yaml` | Spec lint bersih; 10 operasi komunitas | ya |
| T-009 | `contract-gen`: gabung spec → route Nim + client TS | T-008a, T-008b | `tools/contract-gen/{gen,emit_nim,emit_ts}.nim`, `apps/api/src/routes_gen.nim`, `packages/web-client/` | Generate bersih; handler hilang = error kompilasi; 66 operasi | tidak |
| T-016 | Gerbang perubahan kontrak | T-009 | `tools/contract-gen/check.nim`, `docs/plan/contract-change.md`, `task.d/contract.sh` | `./task contract-check` gagal bila spec berubah tanpa hash baru | ya |
| T-015 | `./task mock-api` dari kontrak | T-009 | `tools/mock-api/`, `task.d/mock.sh` | FE develop tanpa backend | ya |
| T-010 | `archcheck`: aturan impor + scope komunitas | T-018 | `tools/archcheck/{main,rules}.nim` | Pelanggaran → exit ≠ 0; uji negatif | ya |
| T-098 | `archcheck` pemindai literal angka bisnis + allowlist | T-010 | `tools/archcheck/scan_constants.nim`, `allowlist_constants.txt` | Konstanta yang menduplikasi key → build gagal | ya |
| T-011 | CI: 7 job + Gate, timeout 15, cache, SHA-pin, **Dockerfile** | T-018 | `.github/workflows/ci.yml`, `.github/workflows/nightly.yml`, `apps/api/Dockerfile`, `task.d/ci.sh` | YAML parse + skema valid (`actionlint` bila terpasang); `./task ci` lulus lokal; `docker build`/`podman build` dijalankan bila runtime ada, kalau tidak `hadolint` + build-check dilewati dengan alasan tercatat | ya |
| T-012 | Parity tool: recorder/replayer/normalizer/fake clock | T-003 | `tools/parity/` | Satu kasus rekam+replay end-to-end | ya |
| T-013 | Korpus parity v1 | T-014, T-012 | `testdata/parity/v1/` | ≥80 kasus, 48 route, manifest ber-checksum | tidak |

**Gate R0:** `./task check` ≤ 60 s; dua DB lokal naik; kontrak 66 operasi ter-generate;
mock API jalan; CI definitions valid.

---

## 3. R1 — Auth, komunitas, sesi

| ID | Task | Depends | Owns | Acceptance | Paralel |
|---|---|---|---|---|---|
| T-020 | Domain `account`: user global, peran komunitas (`admin`/`host`/`member`), `platform_owner`, audit | T-006d, T-006e | `modules/account/domain/roles.nim`, `modules/account/domain/user.nim`, `modules/account/domain/audit.nim` | Matriks 4 peran diuji; `platform_owner` boleh punya membership `member` tetapi tidak otomatis admin; user tanpa komunitas tidak punya peran | ya |
| T-084 | Verifier RS256 (binding OpenSSL) + JWKS cache | T-003 | `modules/account/infrastructure/jwt_rs256.nim` | Vektor Google lulus; boot gagal bila `libcrypto` absen | ya |
| T-021 | OIDC: PKCE, state/nonce, code exchange | T-020, T-084 | `modules/account/infrastructure/oidc_*.nim`, `docs/ops/google-oauth.md` | Login berhasil; state/nonce salah → 400; runbook mencakup pembuatan client, redirect URI, penyimpanan secret 600, rotasi | tidak |
| T-022 | Sesi cookie + store + revoke | T-020 | `modules/account/infrastructure/session_store.nim` | Idle/absolut expiry; revoke langsung 401 | tidak |
| T-078 | Route `/auth/*` (start, callback, logout, me) | T-021, T-022 | `apps/api/src/auth_routes.nim` | Empat route; callback menolak nonce salah | tidak |
| T-085 | OIDC stub + kunci uji untuk E2E/CI | T-021 | `tools/oidc-stub/` | E2E login tanpa Google asli | ya |
| T-023 | RBAC middleware (peran per komunitas + bypass manajemen `platform_owner`) | T-020, T-092 | `apps/api/src/auth_middleware.nim` | 401/403/404 sesuai matriks; bypass hanya untuk aksi manajemen dan menulis audit; baca data domain tanpa join → 404 | tidak |
| T-102 | Token bearer CLI ops (terpisah dari sesi web) | T-022 | `modules/account/infrastructure/ops_token.nim` | Token CLI ditolak di route web | ya |
| T-075 | Rate limit per route/IP; IP dari `X-Client-IP` yang ditulis Caddy | T-003, T-096 | `apps/api/src/ratelimit.nim`, `apps/api/src/config.nim` | 429 + `Retry-After`; ambang dari config; aplikasi **tidak** membaca XFF mentah; XFF palsu dari peer non-proxy tidak mengubah `X-Client-IP` | ya |
| T-076 | CSRF (`Origin`/`Sec-Fetch-Site`) + header keamanan | T-003, T-096 | `apps/api/src/security_headers.nim` | Origin di luar `security.allowed_origins` → 403; CSP/HSTS terkirim | ya |
| T-077 | Idempotency store (key + hash body, scoped komunitas) | T-006d | `modules/platform/idempotency.nim` | Key sama + body beda → 409 | ya |
| T-090 | Domain `community`: slug, settings, direktori, admin pertama | T-006e | `modules/community/domain/` | Slug unik; hanya `platform_owner`; pembuatan wajib menyertakan email admin pertama; direktori butuh login | ya |
| T-091 | Keanggotaan, undangan, pengajuan join, join platform owner | T-090, T-020 | `modules/community/infrastructure/{membership,invite,join_request}.nim`, `apps/api/src/join_routes.nim` | `POST /c/{slug}/join` (platform_owner) dan `join-request` (pengguna); pengajuan ganda pending → 409; `admin` approve/reject lewat `PATCH`; `UNIQUE(community_id,user_id)` | ya |
| T-092 | Middleware konteks komunitas (slug → 404) + allowlist baca publik | T-090, T-020 | `apps/api/src/community_context.nim` | Slug asing/bukan anggota → 404; tanpa login hanya peringkat & `/s/{code}` yang bisa dibaca | tidak |
| T-094 | Suite keamanan cross-tenant | T-092 | `apps/api/tests/tenant/` | Setiap resource: komunitas lain → 404, termasuk `platform_owner` yang belum join; aksi manajemen platform_owner diizinkan tetapi menulis audit | ya |
| T-096 | Registry config + seed L1 | T-006d, T-003 | `modules/platform/config/`, `db/seeds/platform_config.sql` | Key wajib hilang → tolak start; ubah nilai tanpa restart | tidak |
| T-097 | API admin parameter + override komunitas + audit | T-096, T-023 | `apps/api/src/config_routes.nim` | Di luar plafon → 400; audit lama/baru/aktor | ya |
| T-103 | Bootstrap: `platform_owner` pertama (via `--sub`), komunitas default, seed config | T-096, T-091 | `tools/ownerseed/` | Instance kosong bisa dipakai tanpa SQL manual; `--sub` wajib; hanya satu `platform_owner` aktif, penambahan via CLI + audit; tanpa membership otomatis | tidak |
| T-105 | Janitor retensi: flow OAuth, idempotency key, outbox, tautan kedaluwarsa, tiket WS, audit lama | T-006d, T-022 | `modules/platform/janitor.nim`, `apps/api/tests/janitor/` | Baris kedaluwarsa terhapus (termasuk `ws_ticket`); baris aktif tidak tersentuh; jumlah terhapus muncul di metrik | ya |
| T-024 | Share links: hash + ciphertext (nonce/tag/AAD), keyring `SHARE_CODE_KEYS`, tampil-ulang ber-audit, CLI rotasi | T-006a | `modules/share/`, `tools/sharekeys/` | Boot gagal tanpa kunci aktif; rotasi idempoten dan tautan lama tetap terbaca; tampil ulang hanya `admin`/`host` + audit; 128-bit | ya |
| T-025 | Session read API (list tanpa kode, by id, by view_code) | T-009, T-024, T-092 | `modules/session/read*.nim` | SES-01/02; hanya komunitas aktif | tidak |
| T-026 | Session write API granular + OCC; lock menstempel `approved_at` | T-025, T-077 | `modules/session/write*.nim` | Replay idempoten; versi basi 412; tanpa delete+insert; lock tidak menulis `rating_events` | tidak |
| T-027 | WS hub + tiket sekali pakai (sesi & penonton) + pencabutan + batas watcher | T-009, T-025 | `apps/api/src/live.nim`, `apps/api/src/ws_ticket.nim` | Kanal kanonik `session:<id>`/`share:<link_id>`; tiket 60 s sekali pakai; logout/rotasi/demosi menutup socket **dan** menghapus tiket kanal itu; 51 watcher → `full` | ya |
| T-028 | FE shell: auth provider, login, `App.tsx`, manifest rute, i18n, vitest, proxy | T-009, T-015, T-078, T-085 | `apps/web/src/auth/`, `apps/web/src/App.tsx`, `apps/web/src/routes.manifest.ts`, `apps/web/src/i18n/`, `apps/web/vitest.config.ts`, `apps/web/vercel.json`, `pnpm-workspace.yaml`, `pnpm-lock.yaml` | Login/logout; menu per peran; `pnpm test`; `vercel.json` menaruh `/api/*` **sebelum** catch-all SPA; `Set-Cookie` lewat proxy diverifikasi di **alias staging** yang terdaftar sebagai redirect URI (bukan preview acak); tidak ada string UI keras | tidak |
| T-093 | FE komunitas: pemilih + halaman `/c/{slug}` | T-028, T-092 | `apps/web/src/community/` | Pindah komunitas tanpa login ulang | tidak |
| T-029 | FE session read | T-028, T-025 | `apps/web/src/pages/SessionListPage.tsx`, `apps/web/src/queries/sessions.read.ts` | Tanpa token di JS | tidak |
| T-030 | FE session write + share UI | T-029, T-026 | `apps/web/src/pages/{GeneratePage,SharedSessionPage}.tsx`, `apps/web/src/queries/sessions.write.ts` | Simpan hanya dengan sesi login | tidak |
| T-101 | Pensiunkan client lama: hapus `setAdminToken` & `endpoints.ts` | T-030, T-029 | `apps/web/src/queries/endpoints.ts` | `grep setAdminToken` = 0; tidak ada importer | tidak |

**Gate R1:** security suite lulus; 3 sesi E2E; cross-tenant 0 bocor; tidak ada token di JS.

---

## 4. R2 — Pemain & poin

| ID | Task | Depends | Owns | Acceptance | Paralel |
|---|---|---|---|---|---|
| T-040 | Domain `player`: CRUD, alias, gender, tier sticky, `user_id` | T-006a | `modules/player/domain/`, `modules/player/infrastructure/` | Delete tidak menghapus delta orang lain | ya |
| T-041 | API pemain + RBAC | T-040, T-009 | `modules/player/api.nim` | Matriks role; parity | tidak |
| T-042 | Domain `rating`: poin murni, parameter registry | T-003, T-096 | `modules/rating/domain/` | Property: monoton, invarian, clamp; per komunitas | ya |
| T-043 | Ingest/revert/rebuild; ticker hanya mengambil sumber `approved` | T-042, T-006b | `modules/rating/infrastructure/` | Lock menstempel `approved_at`; ticker berikutnya membuat tepat satu event per sesi; rebuild deterministik | tidak |
| T-044 | Papan peringkat + snapshot, dataset fixture | T-043, T-099 | `modules/rating/read*.nim` | p95 < 150 ms pada dataset fixture 1 tahun | ya |
| T-045 | Achievement: hitung, backfill idempoten | T-043, T-006b | `modules/achievement/` | Backfill 2× → baris sama; 6 kategori | ya |
| T-048 | Peran `member` + klaim profil (PLY-04) | T-041, T-022, T-091 | `modules/account/domain/member.nim`, `apps/api/src/member_routes.nim`, `modules/player/claim.nim` | Klaim wajib `member`+; `UNIQUE(community_id,user_id)` dipatuhi; pemain tanpa pemilik → 200 idempoten; sudah diklaim → 409; anonimisasi melepas `user_id` sehingga bisa diklaim lagi; merge hanya `admin` + audit | ya |
| T-106 | Siklus hidup akun: nonaktifkan + anonimisasi | T-020, T-022, T-040 | `modules/account/domain/lifecycle.nim`, `apps/api/src/account_routes.nim` | `sub` diganti `sha256(sub)` sehingga login berikutnya ditolak; nama/email dihapus; `player.user_id` di-NULL-kan (klaim dilepas); baris rating utuh; audit mencatat aktor | ya |
| T-046 | FE peringkat + filter | T-044, T-028, T-093 | `apps/web/src/pages/RankingsPage.tsx`, `apps/web/src/pages/__tests__/rankings.test.tsx` | 200 baris per komunitas; a11y; unit test filter & format | ya |
| T-047 | FE detail pemain + badge | T-046, T-045 | `apps/web/src/pages/RatingPlayerPage.tsx` | Riwayat + badge; tanpa sparkline fiktif | ya |

**Gate R2:** parity poin identik pada korpus sintetis; rebuild = angka sama.

---

## 5. R3 — Turnamen & ekspor

| ID | Task | Depends | Owns | Acceptance | Paralel |
|---|---|---|---|---|---|
| T-050 | Domain classic (grup, bracket, standings) | T-006c | `modules/tournament/classic*.nim` | Bracket & standings parity | ya |
| T-051 | Domain team (6×6, 9 match + final) | T-006c | `modules/tournament/team*.nim` | Skor per partai; champion benar | ya |
| T-052 | API turnamen + patch per match | T-050, T-051, T-009 | `modules/tournament/api.nim` | `PATCH .../matches/{id}` satu match | tidak |
| T-053a | FE classic: wizard, grup, bracket | T-052, T-028, T-093 | `apps/web/src/pages/TournamentClassic*.tsx` | Alur classic end-to-end | ya |
| T-053b | FE team: standings, schedule, final | T-052, T-028, T-093 | `apps/web/src/pages/TournamentTeam*.tsx` | Alur team end-to-end | ya |
| T-054 | Ekspor sosial (dimensi dari config) | T-052, T-028 | `apps/web/src/utils/canvas*.ts`, `apps/web/src/utils/__tests__/canvas.test.ts` | Snapshot stabil; ukuran dari config; unit test untuk perhitungan tata letak | ya |

---

## 6. R4 — Ops & cutover

| ID | Task | Depends | Owns | Acceptance | Paralel |
|---|---|---|---|---|---|
| T-060 | `deploy-vps.sh` + smoke + rollback + backup + cutover + `:v1-final` | T-011, T-018, T-064, T-107 | `ops/scripts/{deploy-vps,smoke,rollback,backup,restore}.sh` | Self re-exec; `flock -w 900` + `exit 1`; `trap ERR` + `cutover.step` + `--resume-cutover`; memicu dari `cutover.request` dan melewati gate `apps/api/`; `podman login ghcr.io` + pull digest; `:v1-final` dibuat dan diperiksa sebelum rotasi | ya |
| T-061 | Quadlet, Caddy (snippet v1/v2/maintenance + switch), env example | T-060 | `ops/systemd/`, `ops/caddy/`, `ops/env/` | `switch_site` + `caddy validate`; maintenance menolak non-GET `/api/*` dengan 503; Caddy menulis `X-Client-IP` dari `trusted_proxies` dan **membuang** XFF klien; log Caddy meredaksi `/s/<kode>`; env v2 `bm2` + `CUTOVER_SNAPSHOT_SHA256`; token GHCR mode 600; `index.html` `no-store` | ya |
| T-062 | Observability: `/healthz`, `/readyz` (DB + skema + `cutover_state`), metrics internal, log 0600 | T-003, T-006d | `apps/api/src/health.nim`, `ops/scripts/rotate-log.sh` | DB mati → 503; `snapshot_sha256` ≠ `CUTOVER_SNAPSHOT_SHA256` → `/readyz` 503; metrics tak publik | ya |
| T-063 | Rehearsal: binary + DB lokal wajib; container bila runtime ada | T-060, T-061, T-062 | `tools/rehearsal/` | Rehearsal memakai `bm_staging` → `bm2_rehearsal`; skenario < 15 menit; rollback dan resume terbukti; restore < 30 menit | tidak |
| T-064 | ETL `bm_staging` → `bm2` + rekonsiliasi (sekali saat cutover) | T-006b, T-006c, T-043, T-090, T-099 | `tools/import/{etl,verify}.nim` | Sumber tunggal `bm_staging` (hasil restore dump); satu transaksi; selisih 0 terhadap staging; semua baris punya `community_id`; **tidak** membuat membership atau tautan | tidak |
| T-095 | Pemetaan v1 → komunitas default | T-064, T-090 | `tools/import/community_map.nim` | Satu komunitas default; idempoten | tidak |
| T-065 | Runbook cutover instan + rollback | T-063, T-064 | `docs/ops/cutover.md` | Urutan maintenance → dump → ETL → tukar env/Caddy → `/readyz` → smoke; rollback ke `:v1-final` teruji; FE lama menerima `410 CLIENT_OUTDATED` | tidak |
| T-082 | Dekomisi Go + hapus `:v1-final` | T-065 + 14 hari observasi (bukti di `docs/ops/cutover.md`) | `apps/api/cmd/`, `apps/api/internal/`, `apps/api/api/`, `apps/api/go.mod`, `apps/api/go.sum`, `apps/api/Makefile`, `apps/api/README.md`, `Makefile`, `README.md`, `package.json` | `grep -r "\.go\b\|go build\|go test" apps/ package.json Makefile .github/` = 0 (baca saja, tidak menyunting CI); CI tanpa job Go; `pnpm install --frozen-lockfile` tetap bersih | tidak |
| T-083 | ADR-011: P0 diterima + cara mencabut | T-021 | `docs/plan/ADR-011.md` | Kondisi, dampak, pemicu tinjau ulang | ya |
| T-107 | Versioning & release: SemVer 2.0 dari Conventional Commits, `VERSION` mulai `2.0.0`, CHANGELOG, SSH-signed tag, image sekali di CI, GitHub Release ber-digest | T-011, T-018 | `VERSION`, `CHANGELOG.md`, `task.d/release.sh`, `tools/release/`, `.github/workflows/release.yml`, `.github/allowed_signers`, `docs/ops/release.md` | `--dry-run` menghitung bump dan `--pre rc`; tag tanpa tanda tangan/tree kotor ditolak; image didorong ke GHCR; urutan push tag → tunggu digest → `main`; workflow gagal = `main` tidak didorong | ya |
| T-108 | Higiene pra-push: keluarkan `docs/audits` dari riwayat yang akan diterbitkan, pindahkan ke `.local/`, pasang hook penolak | T-011 | `.gitignore`, `.githooks/pre-push`, `task.d/hooks.sh`, `docs/ops/pre-push.md` | `git filter-repo --version` jalan (alat diperbaiki dulu); hook menolak push bila `docs/audits` ada; `origin` dipasang kembali setelah rewrite; push pertama `--force-with-lease`; `git log --all` bersih | tidak |

---

## 7. Lintas-rilis

| ID | Task | Depends | Owns | Acceptance | Paralel |
|---|---|---|---|---|---|
| T-070 | Security suite bernama (IDOR, eskalasi, CSRF, replay OAuth, open-redirect, rate limit) | T-014, T-023, T-075, T-076, T-085 | `apps/api/tests/security/` | Merah di v1, hijau di v2; `view_code` tak bisa menulis; `Origin` hilang/asing ditolak; `return_to` `//`, `/\`, `%2F%2F`, dan absolut ditolak | ya |
| T-071 | Perluas korpus parity per modul | T-013 | `testdata/parity/v2/` | Tiap route punya kasus contract+parity | ya |
| T-072 | A11y + visual regression | T-029, T-030, T-046, T-053a, T-053b, T-085 | `e2e/`, `apps/web/playwright.config.ts` | 0 violation; snapshot stabil; login lewat stub OIDC, bukan Google asli | ya |
| T-073 | Sinkron dokumen (routes, openapi, data-model) | T-009 | `docs/handbook/` | Dokumen = kode | ya |
| T-074 | Soak 1 juta request + 50 watcher | T-027, T-062 | `tools/soak/` | RSS tidak monoton; p95 stabil | ya |

---

## 8. Graf dependensi (ringkas)

```text
T-001 ── T-018 ──┬─ T-002
                 ├─ T-003 ──┬─ T-012 ── T-013 ── T-071
                 │          ├─ T-062 ── T-074
                 │          ├─ T-075
                 │          ├─ T-076
                 │          └─ T-084 ── T-021 ── T-022 ──┬─ T-078 ── T-028
                 │                                        └─ T-102
                 ├─ T-004 ── T-005 ── T-006a ──┬─ T-006b ──┬─ T-043 ──┬─ T-044 ── T-046 ── T-047
                 │                             │           │          └─ T-045
                 │                             │           └─ T-064 ── T-095
                 │                             ├─ T-006c ──┬─ T-050 ─┐
                 │                             │           └─ T-051 ─┴─ T-052 ──┬─ T-053a
                 │                             │                               ├─ T-053b
                 │                             │                               └─ T-054
                 │                             ├─ T-006d ──┬─ T-020 ── T-021
                 │                             │           ├─ T-077
                 │                             │           └─ T-096 ──┬─ T-097
                 │                             │                      └─ T-103
                 │                             └─ T-006e ──┬─ T-090 ──┬─ T-091 ── T-048
                 │                                          │          └─ T-092 ──┬─ T-023 ── T-070
                 │                                          │                    ├─ T-094
                 │                                          │                    └─ T-093
                 ├─ T-007 ──┬─ T-099 ── T-014 ── T-013
                 │          └─ T-005
                 ├─ T-008a ─┐
                 ├─ T-008b ─┴─ T-009 ──┬─ T-016
                 │                     ├─ T-015 ── T-028
                 │                     └─ T-027
                 ├─ T-010 ── T-098
                 └─ T-011 ──┬─ T-060 ──┬─ T-061 ── T-063 ── T-065 ── T-082
                             │          └─ T-064
                             ├─ T-107
                             └─ T-108
T-024 ── T-025 ── T-026 ── T-030 ── T-101
T-029 ── T-030
```

---

## 9. Pembagian agen

| Agen | Lane | Boleh mulai | Berhenti bila |
|---|---|---|---|
| A1 | Platform inti (T-001, T-002, T-003, T-010, T-011, T-018, T-098) | sekarang | `./task check` + CI lokal hijau |
| A2 | DB & fixtures (T-004, T-005, T-006a–e, T-007, T-014, T-099) | setelah T-003 | dua DB naik, migrasi bersih |
| B1 | Account (T-020..T-022, T-078, T-084, T-085, T-102, T-106) | setelah T-006d | gate R1 auth |
| C1 | Session/share (T-024..T-027) | setelah T-006a, T-009 | gate R1 sesi |
| D1 | Pemain & rating (T-040–T-045) | setelah T-006b, T-096 | parity poin |
| E1 | Tournament (T-050..T-052) | setelah T-006c | gate R3 |
| F1 | Contract & FE (T-008a/b, T-009, T-015, T-016, T-028..T-030, T-046, T-047, T-053a/b, T-054, T-093, T-101) | setelah T-018 | gate R3 |
| I1 | Security plumbing (T-023, T-075..T-077, T-092, T-094) | setelah T-003 | suite T-070 hijau |
| J1 | Config & community (T-090, T-091, T-096, T-097, T-103, T-105) | setelah T-006d/e | R1 boot tanpa SQL manual |
| H1 | Quality (T-012, T-013, T-070..T-074) | setelah T-012 | korpus & suite hijau |
| G1 | Ops (T-060..T-065, T-082, T-083, T-095, T-107, T-108) | setelah T-011 | rehearsal lulus; rilis pertama terbit dari tag |

---

## 10. Traceability PRD → task

| Requirement | Task |
|---|---|
| COM-01, COM-08 | T-090 |
| COM-02 | T-091 |
| COM-03 | T-091, T-023 |
| COM-04, COM-05 | T-092, T-094 |
| COM-06 | T-093 |
| COM-07 | T-090, T-097 |
| COM-09 | T-020, T-091 |
| COM-10 | T-091, T-094 |
| COM-11 | T-091 |
| AUTH-01, AUTH-02 | T-021, T-084 |
| AUTH-03 | T-023, T-028, T-070 |
| AUTH-04, AUTH-05 | T-022 |
| AUTH-06 | T-102 |
| AUTH-07 | T-076, T-070 |
| AUTH-08 | T-075, T-070 |
| AUTH-09 | T-077, T-026 |
| SES-01, SES-02 | T-025, T-070 |
| SES-03, SES-04 | T-024 |
| SES-05 | T-023, T-026 |
| SES-06, SES-07, SES-08 | T-043 |
| LIVE-01, LIVE-02, LIVE-05 | T-027 |
| LIVE-03 | T-027, T-074 |
| LIVE-04 | T-026 |
| PLY-01 | T-040, T-048 |
| PLY-04 | T-048 |
| AUTH-10 | T-106 |
| AUTH-12 | T-091, T-048 |
| AUTH-13 | T-103 |
| AUTH-11 | T-027 |
| PLY-02 | T-041 |
| PLY-03 | T-040 |
| RNK-01 | T-042, T-043 |
| RNK-02 | T-044, T-046 |
| RNK-03 | T-044 |
| ACH-01, ACH-02 | T-045, T-047 |
| TRN-01 | T-050, T-053a |
| TRN-02 | T-051, T-053b |
| TRN-03, TRN-04 | T-052 |
| EXP-01, EXP-02 | T-054 |
| OPS-01, OPS-02 | T-062 |
| OPS-03 | T-003, T-062 |
| OPS-04, OPS-05 | T-060, T-063 |
| OPS-06 | T-105 |
| OPS-07 | T-107 |
| CFG-01, CFG-02 | T-096 |
| CFG-03, CFG-04 | T-096, T-097 |
| CFG-05 | T-097 |
| CFG-06, CFG-08 | T-098 |
| CFG-07 | T-096, T-097 |

---

## 11. Temuan review yang diterima

| Sumber | Temuan | Perbaikan |
|---|---|---|
| executability | `task`/`config.nims` diklaim satu task | T-018 dispatcher + `task.d/` per task |
| executability | Dockerfile tanpa pemilik | dipindah ke T-011 |
| executability | jalur DB tanpa T-007 | T-005/T-006a depend T-007 |
| executability | tidak ada produsen data untuk T-014 | T-099 generator sintetis |
| executability | config seed tidak ada pemilik | T-096 owns `db/seeds/` |
| executability | kontrak auth bentrok | ADR-015: code flow + callback; memo 04 ditandai |
| executability | T-008 "48 operasi" vs target | T-008a/b, total 66 |
| executability | context & sha256 tanpa pemilik | masuk T-003; T-004 |
| executability | tabrakan `Owns` | T-010/T-098, T-009/T-016, T-020/T-023 dipisah per file |
| executability | tabel tanpa migrasi | `session.links`, trigger version → T-006a; `import_row_map`, `user_id` → T-006a/d |
| executability | acceptance tak terverifikasi | T-016 lokal, T-085 stub OIDC, T-044 dataset T-099, T-063 binary-mode |
| executability | T-082 tidak bisa "grep bersih" | `Owns` diperluas ke go.mod/sum, Makefile, CI |
| executability | client lama tak dipensiunkan | T-101 |
| consistency | 26 tabel | 27 |
| consistency | SES-02 403 vs 401 | 401 untuk belum login, 403 untuk peran kurang |
| consistency | PLY-01 anonim | registrasi wajib login |
| consistency | `public_id` vs `id` | ADR-016: `id` UUIDv7 |
| consistency | `view_code` per komunitas vs `/s/{code}` | ADR-017: unik global |
| consistency | ADR-010 tanpa desain | baris `member` masuk matriks §7.3 |
| consistency | AUTH-06 → T-061 | T-102 |
| adversarial | pool 8 vs `serverThreads` 10× core | T-004: pool = serverThreads |
| adversarial | NULL → `""`, `?` di jsonb | binder PQexecParams + uji NULL/jsonb |
| adversarial | nimcache per nama file | T-018 `--nimcache` per worktree |
| adversarial | FK komposit + kolom NULL | TECH-SPEC §4 butir 11; relasi opsional pakai CHECK/trigger |
| adversarial | bootstrap instance kosong | T-103 |
| adversarial | `libcrypto` dynlib | cek saat boot (T-084), bukan build |
| round-2 security | redirect OAuth di host salah | callback lewat `/api/*`, `return_to` relatif, test open-redirect |
| round-2 security | IP di balik dua proxy | `trusted_proxy_cidrs` + aturan hop kanan |
| round-2 security | tiket WS tanpa store / bocor log | `platform.ws_ticket` + redaksi `ticket` |
| round-2 cutover | ETL dua pemilik | ETL sekali di `CUTOVER=1`; pra-impor hanya rehearsal |
| round-2 cutover | script lama dipakai pada push cutover | self re-exec |
| round-2 cutover | `flock` membuang deploy, gate healthz | `flock -w 900` + `exit 1`, gate `/readyz` |
| round-2 cutover | v1 hilang dari `:prev` | `:v1-final` 14 hari |
| round-2 cutover | digest rilis tak jelas | build sekali di CI, deploy by digest |
| round-2 product | poin tidak pernah di-approve | lock = approval |
| round-2 product | komunitas tanpa admin | email admin pertama di COM-01 |
| round-2 product | penonton tanpa tiket | `POST /s/{code}/ws-ticket` |
| round-2 product | klaim pemain tanpa aturan | PLY-04 |

**Ditolak:** tidak ada. Semua temuan ketiga review diterima; yang tidak bisa
diverifikasi hanya angka baris memo (dokumentasi, bukan desain).
