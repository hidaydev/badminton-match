# TECH-SPEC — Majadu v2 (Nim)

Status: draft untuk review
Tanggal: 2026-11-03
Rujukan: `BRD.md`, `PRD.md`, `BACKLOG.md`, `memos/01..06`

---

## 0. Prinsip

1. **Kontrak dulu, kode kemudian.** OpenAPI ditulis tangan, lalu di-generate menjadi
   kerangka route (Nim) dan tipe client (TS). Handler yang hilang = error kompilasi.
2. **Satu tempat untuk satu aturan.** Validasi skor, poin, generator, dan otorisasi
   hanya di backend. Frontend menampilkan, tidak memutuskan.
3. **Gagal berisik, bukan senyap.** Tidak ada `exit 0` yang membuang rilis, tidak ada
   error setelah commit yang berubah jadi 5xx, tidak ada test yang di-skip tanpa jejak.
4. **Divergensi dari v1 harus dinyatakan.** Parity harness bukan alat membekukan bug.
5. **Repo publik = nol rahasia.** Tidak ada secret, IP asli, dump, atau data pribadi.

---

## 1. Fakta terverifikasi (dan koreksi atas audit)

Diambil langsung dari kode, dump skema, dan library — bukan dari ingatan.

| Fakta | Bukti |
|-------|-------|
| 48 route terdaftar di v1 | `apps/api/cmd/server/main.go`, dihitung otomatis |
| Skema `bm`: 26 tabel, 26 index, 4 fungsi | dump schema-only 2026-11-03 (lokal, tidak di repo) |
| `rating_deltas` **sudah** punya PK `(event_id, player_id)` | dump, constraint `rating_deltas_pkey` |
| `rating_events_order_uniq (date, created_at, source_id, game_order)` **sudah ada** | dump |
| `db_connector` meng-escape string, **bukan** server-side bind | `db_postgres.nim:118` (`dbQuote`) + `db_common` |
| Mummy tidak menyediakan SSE | memo 01; v2 majadu memakai WebSocket |
| ORC pernah `SIGSEGV` di cbs pada 1.16M request | memo 01; alasan `--mm:atomicArc` |
| `nimble.lock` mematikan path global → `nim c` polos gagal | memo 01/05 |

**Koreksi terhadap audit 2026-11-03:**

| Klaim audit | Status | Dasar |
|-------------|--------|-------|
| 07 P2: `rating_deltas` tanpa UNIQUE `(event_id,player_id)` | **salah** | PK sudah ada |
| 07 P1-4: index urut 4 kolom tidak ada | **salah** | `rating_events_order_uniq` |
| 06 P0-1: `/ratings/rebuild-all` hilang dari dokumentasi | **sebagian salah** | route ada di `main.go:249`; yang salah hanya openapi |
| 05/memo: IP server bocor di `ops/caddy/Caddyfile.api.qouver.com` | **salah** | `198.51.100.10` = RFC 5737 (contoh), bukan IP asli |
| memo 02: trigger pada `bm.player_ratings` | **typo** | nama tabel v1 `bm.rating_players` |

Konsekuensi: audit yang tidak bisa melihat baseline `000001–000012` menghasilkan
false positive. Mulai sekarang, klaim skema **wajib** diverifikasi ke dump.

---

## 2. Stack

| Lapisan | Pilihan | Alasan | Ditolak |
|---------|---------|--------|---------|
| Bahasa | Nim `>= 2.4.0 & < 2.5.0` | Sama dengan dua repo live; toolchain dipin sha256 | — |
| HTTP | Mummy 0.4.8 | Terbukti di produksi; 54k rps spike | stdlib (`asynchttpserver` terlalu mentah) |
| Realtime | WebSocket (Mummy) | Mummy tidak bisa SSE; v2 majadu sudah pakai WS | SSE |
| DB | `db_connector` (commit-pin) + pool sendiri + **binder baru** | Satu-satunya driver yang terbukti | — |
| Migrasi | `tools/dbtools` sendiri (ledger + checksum) | Pola majadu; tidak ada tool Nim matang | Flyway, sqitch |
| Config | env untuk rahasia/ops, tabel DB untuk parameter bisnis | Memisahkan dua jenis konfigurasi | config registry majadu (terlalu berat) |
| Log/metrics | logger ~3KB + registry counter/gauge, listener terpisah | Tanpa dependensi; kontrol penuh | chronicles (bila tak perlu) |
| Test | `std/unittest`, satu binary per modul, integrasi **gagal** tanpa DB | Menutup 56/74 test yang selalu skip | — |
| Crypto | nimcrypto 0.7.3 + OpenSSL EVP untuk RSA | Lihat §7.1 | JWT library pihak ketiga |
| Memory | `--mm:atomicArc` | Hindari ORC; YRC ditolak Mummy saat compile | ORC, refc |
| Frontend | React 19 + Vite + Tailwind 4 (dipertahankan) | Sudah ada, timnya satu orang | rewrite FE (tidak perlu) |

**Dependensi wajib dipin persis** (tanpa `nimble.lock`, dengan `deps-check` yang
memverifikasi hash tree): `mummy 0.4.8`, `nimcrypto 0.7.3`, `zippy 0.10.20`,
`webby 0.2.1`, `crunchy 0.1.11`, `nimsimd 1.3.2`, `db_connector` (commit pin).

---

## 3. Struktur repo

```text
badminton-match/
├── task                        # satu-satunya sumber flag build (POSIX)
├── config.nims                 # path modul; dipakai nimsuggest & nim c polos
├── apps/
│   ├── api/                    # entrypoint: main.nim, server.nim, routes_gen.nim
│   └── web/                    # React (dipertahankan, dirework bertahap)
├── modules/                    # 8 domain, tiap modul punya permukaan api.nim
│   ├── session/                # domain/ infrastructure/ migrations/ tests/ api.nim
│   ├── player/
│   ├── rating/
│   ├── tournament/
│   ├── achievement/
│   ├── share/
│   ├── platform/               # config, audit log, clock, id
│   └── account/                # OIDC, sesi, role
├── packages/
│   ├── contracts/openapi/api.yaml   # SUMBER KEBENARAN kontrak
│   └── web-client/                  # TS client hasil generate
├── shared/platform-lib/        # logger, metrics, clock, uuidv7, db binder
├── tools/
│   ├── dbtools/                # migrate/verify/seed
│   ├── archcheck/              # menegakkan aturan impor antar modul
│   └── parity/                 # recorder + replayer
├── ops/                        # caddy, env example, scripts, systemd, webhook
└── docs/
```

**Aturan impor (dijaga `tools/archcheck`):**

| Dari | Boleh | Dilarang |
|------|-------|----------|
| `domain/` | stdlib + `shared/platform-lib` tipe murni | DB, HTTP, logger |
| `infrastructure/` | domain + driver | modul lain |
| `api.nim` (permukaan) | domain + application | infrastructure langsung |
| `apps/api` | semua `api.nim` | SQL mentah |

Rumus poin **wajib** di `modules/rating/domain` — bukan di store seperti v1
(`store/rank_points.go:68-125`).

---

## 4. Data

**Keputusan: skema baru `bm2` di instance PostgreSQL yang sama. `bm` nol DDL.**

| Kriteria | 1:1 `bm` | Evolve `bm` | **Redesign `bm2`** |
|----------|----------|-------------|--------------------|
| Risiko ke prod | rendah | tinggi | rendah |
| Biaya migrasi | nol | sedang | tinggi (sekali) |
| Utang v1 ikut | ya | sebagian | tidak |
| Kerja paralel | sulit | sedang | mudah |

Alasan memilih redesign: `DeletePlayer` menghapus riwayat pemain lain, `Save()`
mereset `version` lewat delete+insert, `share_code OR id::text` mematikan PK, dan
timezone campur. Semuanya hanya bisa dibetulkan dengan mengubah bentuk tabel.

**Perbaikan yang masuk desain:**

1. `session.games` upsert dengan `UNIQUE(session_id, round_no, court_no)` + trigger
   `version`; tidak ada delete+insert (juga menyelamatkan `fix_matches.slot_*`).
2. `rating.deltas` FK `ON DELETE RESTRICT` — hapus pemain tidak boleh menghapus
   delta pemain lain.
3. Index riil: `player_achievements(achievement_key)`,
   `sessions(session_date desc, updated_at desc)`,
   `rating_deltas(event_id, side, player_id)`, `tournament_matches(pair_a_id)`,
   `tournament_matches(pair_b_id)`; hapus 6 pasang index duplikat.
4. `session.links` (bukan `share_links` — satu nama): `id`, `session_id`,
   `kind ('view'|'edit')`, `code_hash`, `created_at`, `revoked_at`,
   `expires_at`; satu baris hidup per `kind`.
5. Kode akses **hash-only**, satu kunci bertipe per query; tidak ada
   `share_code = $1 OR id::text = $1`.
6. Seed poin memakai `ON CONFLICT DO NOTHING` (menggantikan `000023` yang menimpa
   tuning operator).
7. Semua waktu: `timestamptz` UTC untuk instan, `date` WIB untuk tanggal kalender —
   satu konvensi, ditegakkan test.

**Migrasi:** nomor urut, `schema_version` + checksum, dua fase untuk destruktif
(`expand` → backfill → `contract`), DDL hanya lewat `tools/dbmigrate`. App
**menolak start** bila migrasi tertunda atau checksum drift.

---

## 5. API

- Permukaan v2: **48 → 48** route. 7 dihapus tanpa pengganti (`/admin/verify`,
  publik `/metrics`, `/watch`, `/events`, `POST /sessions/{id}/delete`,
  `PATCH /tournaments/{id}`, `ratings/achievements/backfill`), 2 pasang digabung,
  9 baru (auth ×3, share ×3, ws ×2, patch match).
- Konvensi: camelCase, RFC 9457 `problem+json` dengan `code` + `i18nKey`,
  pagination cursor, `Idempotency-Key` + hash body, `ETag`/`If-Match`
  (**412** bila basi, 428 bila tidak dikirim), batas ukuran body per route.
- OpenAPI **ditulis tangan** di `packages/contracts/openapi/api.yaml`; `./task
  contract-gen` menghasilkan kerangka route Nim + client TS. CI gagal bila hasil
  generate berbeda dari commit.
- Tidak ada shim Go. Overlap memakai deploy berpasangan: v1 tetap hidup sebagai
  jalur rollback sampai v2 dinyatakan stabil.

Detail per-route ada di `memos/04-api-contract.md`; ringkasan tabel final masuk
`docs/handbook/features-and-routes.md` saat implementasi.

---

## 6. Realtime

WebSocket di `/ws/sessions/{publicId}` dan `/ws/share/{viewCode}`.

```text
server → client: {"type":"ready"} | {"type":"session.changed","seq":N}
                 {"type":"pong"} | {"type":"full"} | {"type":"revoked"}
client → server: {"type":"ping"} | {"type":"subscribe","lastSeq":N}
```

- **Tidak ada state di kanal.** Frame hanya memberi tahu; klien selalu refetch.
  Ini menghindari dua sumber kebenaran dan membuat reconnect sederhana.
- Batas: 50 watcher/sesi, 20/IP, 500/proses, TTL 60 menit; melebihi → `full`.
- Catch-up: satu `GET` setelah `ready`; `seq` hanya untuk deteksi gap, bukan replay.
- In-memory broadcast **dinyatakan** sebagai single-instance; tidak diklaim durable.

---

## 7. Keamanan

### 7.1 Auth (Google OIDC)

- Authorization Code + PKCE S256, ditukar server-side.
- `state`, `nonce`, `code_verifier` disimpan sebagai **hash** di `auth.oauth_flows`;
  cookie hanya `flow_id` (`__Host-bm_oauth`, 10 menit).
- ID token: `iss`/`aud`/`azp`/`exp`/`nonce`/`email_verified`, `sub` = kunci akun.
- Sesi: cookie opaque 32 byte, hash-only di DB, `__Host-`, `HttpOnly`, `Secure`,
  `SameSite=Lax`; absolut 30 hari, idle 14 hari; revoke satu transaksi dengan
  perubahan role.
- **Tidak ada** access/refresh token Google yang disimpan, tidak ada token di JS.

### 7.2 Konflik yang harus diselesaikan sebelum R1

Memo 01 menyimpulkan "nimcrypto tanpa RSA → validasi klaim saja lewat TLS".
Memo 02 mensyaratkan "RS256 only, JWKS `kid`". Keduanya tidak bisa benar bersamaan.

**Resolusi yang diusulkan:** verifikasi tanda tangan RS256 lewat **OpenSSL `EVP_DigestVerify*`**.
Catatan hasil verifikasi: wrapper bawaan Nim (`lib/wrappers/openssl.nim`)
**hanya** mengekspos `EVP_DigestSignInit`/`EVP_DigestSignFinal` — tidak ada
`EVP_DigestVerify*`, tidak ada `RSA_new`/`BN_bin2bn`/`EVP_PKEY_assign_RSA`.
Jadi ini bukan "pakai yang sudah ada", melainkan **modul binding lokal ±80–120 baris**
(`importc` ke `libcrypto`) plus test vektor dari Google JWKS. Itu tetap lebih murah
daripada dependensi RSA baru dan tetap tanpa library tambahan, tapi harus
diperlakukan sebagai spike, bukan asumsi.
Jalur "klaim saja" hanya dipakai bila spike gagal **dan** token diterima langsung
dari token endpoint over TLS — dicatat sebagai peringatan, bukan default.

### 7.3 Otorisasi & kapabilitas

| Kapabilitas | Siapa |
|-------------|-------|
| Baca sesi via tautan | pemegang `view_code` |
| Tulis skor via tautan | pemegang `edit_code` (header `X-Edit-Code`) |
| Buat sesi/turnamen | `host`+ |
| Merge/rename/delete pemain, tier | `admin`+ |
| Rebuild/revert/ingest | `admin`+ |
| Kelola role | `owner` |

### 7.4 Remediasi P0/P1

| Temuan | Ditutup oleh |
|--------|--------------|
| IDOR `share_code` | `view_code`/`edit_code` terpisah, hash-only, list tanpa kode, `edit_code` di header |
| Pemalsuan poin | `POST` wajib `host`; ingest hanya sumber `approved`; lock tidak ingest |
| Token admin di localStorage | sesi cookie `HttpOnly`; tidak ada token di JS |
| CORS wildcard | origin allowlist; stream tidak lagi `*` |
| Rate limit satu bucket | `MAJADU_TRUSTED_PROXY_CIDR` wajib; limit per route |
| SSE watcher tanpa batas | batas per sesi/IP/proses (§6) |
| Log 0644 | 0600 + tanpa PII |
| `/metrics` publik | listener internal |
| Turnamen anonim | `host`+ untuk semua tulis |
| CSRF | cookie `SameSite=Lax` + gerbang `Origin`/`Sec-Fetch-Site` untuk semua metode non-GET |
| Rate limit per route | limit per route + IP dari proxy tepercaya, 429 + `Retry-After` |

### 7.5 Selama P0 masih terbuka (v1 produksi)

Keputusan pemilik: tidak ada hotfix Go. Kontrol kompensasi yang **tidak** menyentuh
kode v1 (butuh aksi di host, jadi harus disetujui):

- K2/K3: rate limit di edge + `404` untuk `/metrics`, `/version`, `/admin/verify`.
- K4: access log 0600 + alarm lonjakan tulis per IP.
- K5: dump forensik harian disimpan terpisah.
- K6: `statement_timeout` pada role aplikasi.
- K1 (opsional, berbiaya produk): freeze ingest poin lewat trigger DB.

Yang **tidak bisa** ditutup di edge: enumerasi `GET /sessions` dan mutasi skor
anonim. Keduanya baru benar-benar tertutup saat API Nim rilis.

---

## 8. Build, CI/CD, operasional

**Build:** satu sumber flag di `./task build`:
`-d:release --opt:speed --threads:on --mm:atomicArc`. Nim 2.4.0 dipin di CI,
Dockerfile (tarball + sha256), dan `.nimble`. `-static` ditolak (libpq dynlib).

**CI** (semua `timeout-minutes: 15`, action di-pin SHA, `${{ }}` hanya di `env:`):

| Job | Isi |
|-----|-----|
| Repo | format, `nim check`, archcheck, unit |
| Database | migrate dari nol + integrasi |
| Web | types, lint, build |
| Browser | E2E + axe |
| Image | build + container smoke |
| Security | gitleaks (full history), deps, osv |
| Gate | agregator `if: always()` (agar `paths-ignore` tidak menggantung required check) |

Nightly: gitleaks penuh, osv-scanner, drift `--pull=always`, `ci-repeat 2`.

**Image:** multi-stage, `debian:bookworm-slim@sha256`, uid 10001, HEALTHCHECK,
≤120 MB, digest reproducibility diuji.

**Deploy (`ops/scripts/deploy-vps.sh`)** wajib: ref-guard fail-closed, `flock`,
`fetch` + `reset --hard`, retensi hanya `:local` dan `:prev`, `--build-arg`
VERSION/COMMIT/DATE, gate `/readyz`, rollback otomatis terverifikasi, notifikasi
gagal, `smoke.sh` + `rollback.sh` terpisah.

**Observability:** `/healthz` (proses), `/readyz` (DB + versi skema), metrics di
listener internal, log terstruktur tanpa PII, retensi 7 hari.

---

## 9. Testing

| Lapis | Isi | Target |
|-------|-----|--------|
| Unit | domain murni | < 5 s, domain ≥ 90% |
| Property | poin, generator, validasi skor, standings | 10k kasus/menit |
| Integrasi | DB nyata, satu binary per modul | gagal bila DB tak ada |
| Kontrak | OpenAPI ↔ handler ↔ client | generate bersih |
| Parity | golden JSON v1 vs v2 | 80 kasus < 90 s |
| E2E | alur host+guest, login, live | < 5 menit |
| A11y/visual | halaman inti | 0 violation |

**Parity harness** (lihat `memos/06`): capture sekali pada commit+dump ber-checksum;
`state.json` menyimpan hash tabel sesudah request sehingga bug "commit lalu 500"
tertangkap. Toleransi angka **nol**. Fake clock `MAJADU_NOW` wajib sejak hari pertama.
Divergensi sengaja dideklarasikan per kasus dan **harus tetap berbeda** — kalau Nim
malah identik dengan v1 pada kasus IDOR, test gagal.

Isolasi DB: `bm2_template` + `CREATE DATABASE … TEMPLATE` per worker (~300 ms),
reset `TRUNCATE` urut FK, guard nama DB wajib `_test`/`_ci`.

Gate: `./task check` ≤ 60 s · `./task verify <module>` ≤ 5 min · `./task ci` ≤ 20 min.

---

## 10. Migrasi & cutover

1. R0–R3 berjalan lokal; v1 tetap di produksi tanpa perubahan.
2. Rehearsal deploy di pod lokal: build, restart, health gagal, rollback.
3. Cutover: deploy v2 berpasangan dengan v1 tetap tersedia sebagai `:prev`.
4. Import data `bm` → `bm2` **setelah** v2 stabil, dengan rekonsiliasi
   (jumlah baris, checksum agregat, sampel acak), dan `platform.import_row_map`.
5. Poin **dihitung ulang** dari event, bukan disalin; snapshot v1 dipakai sebagai
   fixture verifikasi.
6. Rollback = kembali ke image `:prev`; skema `bm2` tidak dihapus.

---

## 11. Risiko teknis

| # | Risiko | Mitigasi | Pemicu pembalikan |
|---|--------|----------|-------------------|
| T1 | Mummy + memory manager tidak stabil | `atomicArc`, RSS gauge, soak 1 juta request | RSS naik monoton |
| T2 | Binder SQL bocor | binder wajib + round-trip test + lint melarang `dbQuote` di store | ada query tanpa binder |
| T3 | OIDC tanpa verifikasi tanda tangan | spike OpenSSL EVP (§7.2) | EVP tidak tersedia |
| T4 | Cold compile Nim mendekati 15 menit | nimcache + `deps.lock` + job terpisah | CI > 12 menit |
| T5 | Parity membekukan bug | divergensi wajib | ada kasus "sama dengan v1" pada IDOR |
| T6 | Waktu tidak deterministik | fake clock wajib | fixture kedaluwarsa |
| T7 | Redesign skema kehilangan data | import hanya setelah rekonsiliasi, `bm` utuh | selisih rekonsiliasi > 0 |

---

## 12. Keputusan yang perlu ADR

| ID | Judul | Status |
|----|-------|--------|
| ADR-001 | Rewrite di repo ini, bukan di majadu v2 | diterima (O-1) |
| ADR-002 | Skema `bm2` baru, `bm` nol DDL | diterima (memo 03) |
| ADR-003 | WebSocket, bukan SSE | diterima (memo 01/04) |
| ADR-004 | Kontrak ditulis tangan + codegen | diterima (memo 04) |
| ADR-005 | Binder SQL wajib | diterima (memo 01) |
| ADR-006 | Google OIDC untuk host/admin, `edit_code` untuk guest | diterima (O-3) |
| ADR-007 | Parity harness + divergensi deklaratif | diterima (memo 06) |
| ADR-008 | Tanpa shim Go, cutover berpasangan | diterima (memo 04) |
| ADR-009 | Verifikasi RS256 via modul binding OpenSSL (`EVP_DigestVerify*` belum ada di wrapper Nim) | **terbuka** (§7.2) |
| ADR-010 | Model `member` masuk R1 atau tidak | **terbuka** (PRD §9) |
