# BACKLOG — Majadu v2 (Nim)

Status: draft v2 (setelah review scrum master)
Tanggal: 2026-11-03
Rujukan: `PRD.md`, `TECH-SPEC.md`, `memos/`, `REVIEW-scrum.md`

Backlog ini dirancang untuk **dikerjakan paralel oleh subagent**. Aturannya
bukan "sebanyak mungkin", tapi "sebanyak yang tidak saling menimpa file".

---

## 0. Protokol paralel

1. **`Owns` wajib setingkat file atau direktori terdalam**, bukan `apps/api/`.
   Dua task yang `Owns`-nya beririsan tidak boleh jalan bersamaan.
2. **Kontrak lebih dulu.** Perubahan bentuk request/response mengubah
   `packages/contracts/openapi/api.yaml` lewat task kontrak (T-016), baru
   implementasi. `api.yaml` tidak boleh disentuh task lain.
3. **Merge order = dependency order.** Tanpa edge → bebas. Ada edge → arah menang.
4. **Worktree per agen**; merge ke `main` lokal hanya oleh orchestrator.
5. **Tidak ada push.** Remote tidak disentuh sampai R4.
6. **DoR**: acceptance terukur, `Owns` spesifik, dependency eksplisit.
   **DoD**: acceptance lulus, `./task check` hijau, `./task verify <modul>` hijau,
   nol test di-skip tanpa alasan tertulis.

Konkurensi maksimum: **4 agen aktif** (2 backend, 1 frontend, 1 platform/infra).

---

## 1. Peta workstream

| Lane | Domain | Pemilik file utama |
|------|--------|--------------------|
| **A. Platform** | build, db, log, metrics, clock, archcheck, CI | `task`, `config.nims`, `shared/`, `tools/{dbtools,archcheck,contract-gen,rehearsal}`, `.github/` |
| **B. Account** | OIDC, sesi, role, audit, auth routes | `modules/account/`, `apps/api/src/auth*.nim` |
| **C. Session** | setup, generate, skor, live, share | `modules/session/`, `modules/share/`, `apps/api/src/{session*,live}*.nim` |
| **D. Player & Rating** | pemain, poin, papan, badge | `modules/player/`, `modules/rating/`, `modules/achievement/` |
| **E. Tournament** | classic, team, ekspor | `modules/tournament/`, `apps/web/src/pages/Tournament*` |
| **F. Contract & FE** | OpenAPI, codegen, mock, halaman | `packages/`, `apps/web/src/{queries,auth}/` |
| **G. Ops** | image, deploy, observability, cutover | `ops/`, `apps/api/Dockerfile` |
| **H. Quality** | parity, security suite, E2E, a11y | `tools/parity/`, `testdata/`, `e2e/`, `apps/api/tests/security/` |
| **I. Security plumbing** | rate limit, CSRF, idempotency | `apps/api/src/{ratelimit,security_headers}.nim`, `modules/platform/idempotency.nim` |

Lane A memblokir hampir semua lane lain. **A jalan lebih dulu, maksimal 2 agen**,
sampai T-011 selesai.

---

## 2. R0 — Fondasi

| ID | Task | Depends | Owns (file-level) | Acceptance | Paralel |
|----|------|---------|-------------------|------------|---------|
| T-001 | Skeleton repo Nim + `./task` (`check/build/verify/ci`) | — | `config.nims`, `task`, `apps/api/main.nim`, `apps/api/server.nim` | `nim check` polos & `./task check` jalan di macOS arm64 | tidak (blokir semua) |
| T-002 | Pin toolchain + `deps.lock` + `deps-check` | T-001 | `*.nimble`, `deps.lock` | `deps-check` gagal bila tree drift | tidak |
| T-003 | `platform-lib` inti: logger, metrics, clock, ids, errors | T-001 | `shared/platform-lib/*.nim` (kecuali `db/`) | Unit test; clock dipaksa `MAJADU_NOW` | ya (T-004) |
| T-004 | DB layer: pool, tx, **binder parameter** | T-001 | `shared/platform-lib/db/*.nim` | Round-trip: `?` jadi bind nyata; lint melarang `dbQuote` di store | ya (T-003) |
| T-005 | `tools/dbtools`: ledger, checksum, migrate/verify/seed | T-004 | `tools/dbtools/` | Migrasi dari nol < 20 s; checksum drift → exit ≠ 0 | tidak |
| T-006a | Migrasi `bm2` inti: community, session, player, court, game, fix_match | T-005 | `db/migrations/0001_*.sql` | `dbtools verify` bersih; idempoten; semua tabel ber-`community_id` + FK komposit | tidak (blokir 006b–d) |
| T-006b | Migrasi `bm2` rating & achievement | T-006a | `db/migrations/0002_*.sql` | Tabel + index + constraint sesuai TECH-SPEC §4 | ya (dengan 006c) |
| T-006c | Migrasi `bm2` tournament | T-006a | `db/migrations/0003_*.sql` | Idem | ya (dengan 006b) |
| T-006d | Migrasi `bm2` platform/account: `platform.{community,user,idempotency_keys}`, `community.{membership,invite,settings}`, `account.{sessions,audit}`, `auth.oauth_flows`, `outbox` | T-006a | `db/migrations/0004_*.sql` | Idem; **bukan** "26 tabel" — termasuk tabel baru; peran disimpan per keanggotaan | ya (dengan 006b/006c) |
| T-007 | Dev environment: pod Podman, `postgres:18-alpine`, port 55432, template, reset | T-001 | `ops/dev/` | `./task dev-db` naik < 20 s; clone per-worker < 1 s | ya |
| T-014 | Environment v1 lokal: restore dump ke pod terpisah + seed legacy | T-007 | `ops/dev/v1/`, `db/fixtures/v1/` | `./task dev-v1` naik; 48 route v1 merespons | ya |
| T-008 | OpenAPI v2 di `packages/contracts/openapi/api.yaml` | T-001 | `packages/contracts/openapi/api.yaml` | 48 operasi, lint spec bersih | ya |
| T-009 | `contract-gen`: kerangka route Nim + client TS | T-008 | `tools/contract-gen/`, `apps/api/src/routes_gen.nim` | Generate bersih; handler hilang = error kompilasi | tidak (blokir F) |
| T-016 | Gerbang perubahan kontrak: template task + cek hash di CI | T-009 | `docs/plan/contract-change.md`, `tools/contract-gen/check.nim` | PR yang mengubah `api.yaml` tanpa hash baru → gagal | tidak |
| T-015 | `./task mock-api` dari kontrak | T-009 | `tools/mock-api/` | FE bisa develop tanpa backend | ya |
| T-010 | `tools/archcheck`: aturan impor antar-modul | T-001 | `tools/archcheck/` | Pelanggaran → exit ≠ 0; ada uji negatif | ya |
| T-011 | CI skeleton: 7 job + Gate, timeout 15, cache, SHA-pin | T-001 | `.github/workflows/` | `actionlint` bersih + `./task ci` lulus lokal; definisi diverifikasi tanpa push | ya |
| T-012 | Parity tool: recorder + replayer + normalizer + fake clock | T-003 | `tools/parity/` | Rekaman & replay satu kasus end-to-end | ya |
| T-013 | Rekam korpus parity dari v1 | T-014, T-012 | `testdata/parity/` | ≥80 kasus mencakup 48 route; manifest ber-checksum | tidak |

**Gate R0:** `./task check` ≤ 60 s, DB `bm2` + DB v1 lokal naik, kontrak ter-generate,
mock API jalan, CI definitions valid.

---

## 3. R1 — Auth & sesi

| ID | Task | Depends | Owns | Acceptance | Paralel |
|----|------|---------|------|------------|---------|
| T-020 | Domain `account`: user, role, audit | T-006d | `modules/account/domain/` | Unit test matriks role | ya |
| T-021 | OIDC Google: PKCE, state/nonce, JWKS cache | T-020, T-084 | `modules/account/infrastructure/oidc_*.nim` | Login berhasil; state/nonce salah ditolak; `kid` tak dikenal → tolak | tidak |
| T-084 | Verifier RS256: binding OpenSSL `EVP_DigestVerify*` + cache JWKS | T-003 | `modules/account/infrastructure/jwt_rs256.nim` | Vektor uji dari JWKS Google lulus; build **gagal** bila `libcrypto` tidak ada | ya |
| T-022 | Sesi cookie + store + revoke | T-020 | `modules/account/infrastructure/session_store.nim` | Expiry idle/absolut diuji; revoke langsung 401 | tidak (dengan T-021) |
| T-078 | Route `/auth/*` (start, callback, logout) | T-021, T-022 | `apps/api/src/auth_routes.nim` | Tiga route hidup; callback menolak nonce salah | tidak |
| T-023 | RBAC middleware + matriks route×role×komunitas | T-078 | `apps/api/src/auth_middleware.nim`, `modules/account/domain/rbac.nim` | 401/403 sesuai matriks; beda komunitas → 404; test negatif per peran | tidak |
| T-090 | Domain `community`: komunitas, slug, settings | T-006d | `modules/community/domain/` | Slug unik per instance; slug tidak valid ditolak | ya |
| T-091 | Keanggotaan, undangan sekali pakai, peran per komunitas | T-090, T-020 | `modules/community/infrastructure/membership.nim`, `.../invite.nim` | Undangan dipakai 2× → gagal; peran di komunitas A tidak berlaku di B | ya |
| T-092 | Middleware konteks komunitas: slug → `community_id`, 404 | T-090, T-023 | `apps/api/src/community_context.nim` | Slug asing / bukan anggota → 404; handler menerima ctx ber-community | tidak |
| T-093 | FE rute komunitas + pemilih komunitas | T-028, T-092 | `apps/web/src/community/` | `/c/{slug}/…` jalan; pindah komunitas tanpa login ulang | tidak |
| T-094 | Suite keamanan cross-tenant | T-092 | `apps/api/tests/tenant/` | Setiap resource: akses komunitas lain → 404; 0 kebocoran | ya |
| T-075 | Rate limit per route/IP + `trusted_proxy` | T-003 | `apps/api/src/ratelimit.nim`, `apps/api/src/config.nim` | Melebihi batas → 429 + `Retry-After`; IP asli terbaca di belakang proxy | ya |
| T-076 | Gerbang CSRF (`Origin`/`Sec-Fetch-Site`) + header keamanan | T-003 | `apps/api/src/security_headers.nim` | Origin asing → 403; CSP & HSTS terkirim | ya |
| T-077 | Idempotency store (key + hash body) | T-006d | `modules/platform/idempotency.nim` | Key sama + body beda → 409; body sama → hasil sama | ya |
| T-024 | Share links: `session.links`, satu `view_code` read-only per sesi, hash-only, rotasi | T-006a | `modules/share/` | Kode lama 404 setelah rotasi; kode unik per komunitas; tidak ada kode tulis | ya (lane C) |
| T-025 | Session read API (list tanpa kode, get by publicId/view_code) | T-009, T-024, T-092 | `modules/session/read*.nim` | SES-01/02 lulus; hanya sesi komunitas aktif; parity subset | tidak (blokir T-026) |
| T-026 | Session write API granular + OCC (412/428) + idempotency | T-025, T-077 | `modules/session/write*.nim` | Replay idempoten; versi basi 412; tidak ada delete+insert | tidak |
| T-027 | WebSocket hub + batas watcher + heartbeat | T-009, T-025 | `apps/api/src/live.nim` | 51 watcher → `full`; reconnect → state konsisten | ya |
| T-028 | FE auth: provider, login, menu berbasis role | T-008, T-015, T-078 | `apps/web/src/auth/`, `apps/web/src/App.tsx` | Login/logout; menu admin hanya untuk role | ya |
| T-029 | FE session read (list, detail, share view) | T-028, T-025 | `apps/web/src/pages/SessionListPage.tsx`, `apps/web/src/queries/sessions.read.ts` | Render tanpa token di JS | tidak |
| T-030 | FE session write + share UI (login-only) | T-029, T-026 | `apps/web/src/pages/{GeneratePage,SharedSessionPage}.tsx`, `apps/web/src/queries/sessions.write.ts` | Skor tersimpan hanya dengan sesi login; tautan read-only | tidak |

**Gate R1:** security suite P0 lulus, 3 sesi E2E berjalan, tidak ada token di JS.

---

## 4. R2 — Pemain & poin

| ID | Task | Depends | Owns | Acceptance | Paralel |
|----|------|---------|------|------------|---------|
| T-040 | Domain `player`: CRUD, alias, gender, tier sticky | T-006a | `modules/player/domain/`, `modules/player/infrastructure/` | Delete tidak menghapus delta orang lain | ya |
| T-041 | API pemain + RBAC | T-040, T-009 | `modules/player/api.nim` | Matriks role lulus; parity | tidak (butuh T-040) |
| T-042 | Domain `rating`: poin murni | T-003 | `modules/rating/domain/` | Property: monoton, invarian, clamp; window di dalam satu komunitas | ya |
| T-043 | Ingest/revert/rebuild + approval sumber | T-042, T-006b | `modules/rating/infrastructure/` | Rebuild deterministik; lock tidak ingest | tidak |
| T-044 | Papan peringkat + snapshot pergerakan | T-043 | `modules/rating/read*.nim` | p95 < 150 ms pada dataset fixture 1 tahun; filter tier | ya |
| T-045 | Achievement: hitung, backfill idempoten | T-043, T-006b | `modules/achievement/` | Backfill 2× → baris sama; 6 kategori | ya |
| T-048 | Peran `member` + klaim profil pemain (per komunitas) | T-041, T-022 | `modules/account/domain/member.nim`, `apps/api/src/member_routes.nim` | Klaim profil idempoten; `member` tidak bisa menulis admin; klaim hanya di komunitas terkait | ya |
| T-046 | FE peringkat + filter | T-044, T-028, T-093 | `apps/web/src/pages/RankingsPage.tsx` | 200 baris per komunitas, filter, a11y | ya |
| T-047 | FE detail pemain + badge | T-046, T-045 | `apps/web/src/pages/RatingPlayerPage.tsx` | Riwayat + badge; tanpa sparkline fiktif | ya |

**Gate R2:** parity poin identik pada korpus; rebuild dari fixture = angka sama.

---

## 5. R3 — Turnamen & ekspor

| ID | Task | Depends | Owns | Acceptance | Paralel |
|----|------|---------|------|------------|---------|
| T-050 | Domain tournament classic | T-006c | `modules/tournament/classic*.nim` | Bracket & standings parity | ya |
| T-051 | Domain tournament team | T-006c | `modules/tournament/team*.nim` | Skor per partai; champion benar | ya (T-050) |
| T-052 | API turnamen + patch per match | T-050, T-051, T-009 | `modules/tournament/api.nim` | `PATCH .../matches/{id}` mengubah satu match | tidak |
| T-053 | FE tournament classic & team | T-052, T-028, T-093 | `apps/web/src/pages/Tournament*.tsx` | Wizard, bracket, standings, skor di bawah `/c/{slug}` | ya |
| T-054 | Ekspor sosial | T-052 | `apps/web/src/utils/canvas*.ts` | Snapshot visual stabil | ya |

**Gate R3:** E2E turnamen penuh; ekspor deterministik.

---

## 6. R4 — Ops & cutover

| ID | Task | Depends | Owns | Acceptance | Paralel |
|----|------|---------|------|------------|---------|
| T-060 | `deploy-vps.sh`: ref-guard, flock, retensi `:local`/`:prev`, `--build-arg`, `/readyz`, rollback | T-011 | `ops/scripts/deploy-vps.sh`, `ops/scripts/{smoke,rollback}.sh` | Shellcheck bersih; setiap guard punya unit test/skenario; rollback diuji penuh di T-063 | ya |
| T-061 | Quadlet, Caddy, env example | T-060 | `ops/systemd/`, `ops/caddy/`, `ops/env/` | `NoNewPrivileges`, `DropCapability=ALL`, header keamanan | ya |
| T-062 | Observability: `/healthz`, `/readyz` (versi skema), metrics internal, log 0600 | T-003 | `apps/api/src/health.nim`, `ops/scripts/rotate-log.sh` | DB mati → `/readyz` 503; metrics tak publik | ya |
| T-063 | Rehearsal lokal: deploy + rollback + smoke + failure injection | T-060, T-061, T-062 | `tools/rehearsal/` | Skenario lulus dari nol < 15 menit | tidak |
| T-064 | Import `bm` → `bm2` + rekonsiliasi + `import_row_map` | T-006b, T-006c, T-043, T-090 | `tools/import/etl.nim`, `tools/import/verify.nim` | Selisih rekonsiliasi = 0; bisa diulang; semua baris punya `community_id` | tidak |
| T-095 | Pemetaan data v1 ke komunitas default | T-064, T-090 | `tools/import/community_map.nim` | Satu komunitas default; slug tercatat; idempoten | tidak |
| T-065 | Runbook cutover + rollback | T-063, T-064 | `docs/ops/cutover.md` | Bisa diikuti orang lain tanpa bertanya | tidak |
| T-082 | Dekomisi Go: hapus `apps/api/{cmd,internal}`, `apps/api/api/openapi.yaml`, generator FE lama | T-063 | `apps/api/cmd/`, `apps/api/internal/`, `apps/web/scripts/` | Tidak ada referensi Go tersisa; `grep` bersih | tidak |
| T-083 | Catat ADR-011: P0 diterima, konsekuensi, dan cara mencabutnya | T-021 | `docs/plan/ADR-011.md` | Dokumen berisi kondisi, dampak, dan pemicu peninjauan ulang | ya |

---

## 7. Lintas-rilis

| ID | Task | Depends | Owns | Acceptance | Paralel |
|----|------|---------|------|------------|---------|
| T-070 | Security suite bernama (IDOR, eskalasi, CSRF, replay OAuth, rate limit) | T-023, T-075, T-076 | `apps/api/tests/security/` | Merah di v1, hijau di v2; termasuk `view_code` tidak bisa menulis | ya |
| T-071 | Perluas korpus parity per modul | T-013 | `testdata/parity/` | Tiap route punya kasus contract+parity | ya |
| T-072 | A11y + visual regression halaman inti | T-029, T-030, T-046, T-053 | `e2e/` | 0 violation; snapshot stabil | ya |
| T-073 | Sinkron dokumen: `features-and-routes.md`, openapi, `data-model.md` | T-009 | `docs/handbook/` | Dokumen = kode; generate bersih | ya |
| T-074 | Soak: 1 juta request + 50 watcher | T-027, T-062 | `tools/soak/` | RSS tidak naik monoton; p95 stabil | ya |

---

## 8. Graf dependensi

```text
T-001 ──┬─ T-002
        ├─ T-003 ──┬─ T-012 ──┐
        │          ├─ T-062 ──┴─ T-074
        │          ├─ T-075
        │          └─ T-076
        ├─ T-004 ── T-005 ── T-006a ──┬─ T-006b ──┬─ T-043 ──┬─ T-044 ── T-046 ── T-047
        │                             │           │          └─ T-045
        │                             │           └─ T-064
        │                             ├─ T-006c ──┬─ T-050 ─┐
        │                             │           └─ T-051 ─┴─ T-052 ──┬─ T-053
        │                             └─ T-006d ──┬─ T-020 ──┬─ T-021 ── T-022 ── T-078 ── T-023 ── T-070
        │                                         │          └─ T-084
        │                                         └─ T-077
        ├─ T-007 ── T-014 ── T-013 ── T-071
        ├─ T-008 ── T-009 ──┬─ T-016
        │                   ├─ T-015 ── T-028 ── T-029 ── T-030 ── T-072
        │                   └─ T-027 ── T-074
        ├─ T-010
        └─ T-011 ── T-060 ──┬─ T-061 ── T-063 ── T-065
                            └─ T-082
T-042 ── T-043        (domain rating tidak menunggu skema)
T-024 ── T-025 ── T-026 (butuh T-009)
T-090 ── T-091        (komunitas)
T-090 + T-023 ── T-092 ── T-093
T-092 ── T-094
T-090 + T-064 ── T-095
```

Kritis: **T-004 → T-005 → T-006a**, **T-008 → T-009**, dan **T-020 → T-021 → T-022**.
Jangan menambah pekerjaan di jalur ini.

---

## 9. Pembagian agen

| Agen | Lane | Boleh mulai | Berhenti bila |
|------|------|-------------|----------------|
| A1 | Platform inti (T-001..T-011, T-016) | sekarang | CI + kontrak ter-generate |
| A2 | Platform DB (T-004..T-007, T-014) | setelah T-004 | dua DB lokal naik |
| B1 | Account/auth (T-020..T-023, T-048, T-078, T-084) | setelah T-006d | gate R1 |
| C1 | Session/share (T-024..T-027) | setelah T-006a & T-009 | gate R1 |
| D1 | Rating (T-042..T-045) | setelah T-006b | parity poin lulus |
| E1 | Tournament (T-050..T-052) | setelah T-006c | gate R3 |
| F1 | FE (T-028..T-030, T-046, T-047, T-053, T-054) | setelah T-015 | gate R3 |
| I1 | Security plumbing (T-075..T-077) | setelah T-003 | suite T-070 hijau |
| H1 | Quality (T-012, T-013, T-070..T-074) | setelah T-012 | korpus & suite hijau |
| J1 | Community (T-090..T-093, T-095) | setelah T-006d | gate R1 |
| G1 | Ops (T-060..T-065, T-082) | setelah T-011 | rehearsal lulus |

Hanya **orchestrator** yang mengubah `api.yaml` di luar task kontrak T-016.

---

## 10. Matriks traceability PRD → task

| Requirement | Task |
|---|---|
| COM-01 | T-090 |
| COM-02 | T-091 |
| COM-03 | T-091, T-023 |
| COM-04, COM-05 | T-092, T-094 |
| COM-06 | T-093 |
| COM-07 | T-090 (settings) |
| COM-08 | T-090 |
| COM-09 | T-020, T-091 |
| COM-10 | T-091, T-094 |
| AUTH-01, AUTH-02 | T-021, T-084 |
| AUTH-03 | T-023, T-028, T-070 |
| AUTH-04, AUTH-05 | T-022 |
| AUTH-06 | T-061 |
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
| PLY-01, PLY-03 | T-040 |
| PLY-02 | T-041 |
| RNK-01 | T-042, T-043 |
| RNK-02 | T-044, T-046 |
| RNK-03 | T-044 |
| ACH-01, ACH-02 | T-045, T-047 |
| TRN-01 | T-050, T-053 |
| TRN-02 | T-051, T-053 |
| TRN-03, TRN-04 | T-052 |
| EXP-01, EXP-02 | T-054 |
| OPS-01, OPS-02 | T-062 |
| OPS-03 | T-003, T-062 |
| OPS-04, OPS-05 | T-060, T-063 |

---

## 11. Log review scrum master

| Temuan | Keputusan |
|--------|-----------|
| Task keamanan (rate limit, CSRF, idempotency, `/auth/*`) tidak punya pemilik | **diadopsi** → T-075, T-076, T-077, T-078; requirement AUTH-07..09 ditambahkan |
| T-006 terlalu besar & lingkupnya salah ("26 tabel") | **diadopsi** → dipecah T-006a–d, termasuk `auth.*`, `account.*`, `platform.idempotency_keys` |
| T-013 salah bergantung pada DB `bm2` | **diadopsi** → tambah T-014 (env v1 lokal), edge T-014 → T-013 |
| `Owns` glob menabrak (`apps/api/`, `ops/`, `modules/player/`) | **diadopsi** → semua diubah ke file/direktori terdalam |
| Label "Paralel: ya" pada T-041/T-044/T-045 keliru | **diadopsi** → T-041 jadi "tidak" (butuh T-040); T-044/T-045 tetap ya dengan `Owns` terpisah |
| FE tanpa edge ke kontrak & tanpa mock API | **diadopsi** → T-015 (mock), T-016 (gerbang kontrak), edge T-028 → T-008/T-015/T-078 |
| Edge hilang T-046→T-044, T-072→T-029/030, T-074→T-062 | **diadopsi** |
| Edge T-044→T-028 | **ditolak** — papan peringkat publik, backend tidak butuh auth FE |
| T-011 "job hijau di PR" tanpa push | **diadopsi (diubah)** → `actionlint` + `./task ci` lokal |
| T-044 p95 tanpa dataset | **diadopsi** → dataset fixture 1 tahun |
| T-060 acceptance bergantung pada T-063 (sirkular) | **diadopsi** → T-060 hanya shellcheck + skenario guard; drill penuh di T-063 |
| Dekomisi Go belum jadi task | **diadopsi** → T-082 |
| Keputusan freeze poin belum jadi task | **diadopsi** → T-083 |

---

## 12. Yang sengaja belum dipecah

Detail properti OpenAPI (T-008), isi tiap migrasi `bm2` (T-006a–d), naskah runbook
(T-065), dan rencana impor per tabel (T-064). Semua bergantung pada keputusan yang
belum stabil; memecahnya sekarang akan menghasilkan task yang ditulis ulang.
