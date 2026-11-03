# TECH-SPEC — Majadu v2 (Nim)

Status: draft untuk review
Tanggal: 2026-11-03
Rujukan: `BRD.md`, `PRD.md`, `BACKLOG.md`, `memos/01..06`

> **Istilah.** `v1` = backend Go yang berjalan sekarang di repo ini. `v2` = backend
> Nim penggantinya **di repo yang sama**. `majadu` adalah proyek terpisah dan tidak
> disentuh (O-1).

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
6. **Komunitas adalah batas data.** Tidak ada query yang boleh berjalan tanpa
   `community_id`; pelanggaran harus jadi error, bukan hasil kosong.
7. **Angka bisnis hidup di DB.** Kode hanya menyimpan invarian struktural.
   Menambah aturan baru = menambah key config, bukan menambah konstanta.

---

## 1. Fakta terverifikasi (dan koreksi atas audit)

Diambil langsung dari kode, dump skema, dan library — bukan dari ingatan.

| Fakta | Bukti |
|-------|-------|
| 48 route terdaftar di v1 | `apps/api/cmd/server/main.go`, dihitung otomatis |
| Skema `bm`: **27** tabel, 26 index, 4 fungsi | dump schema-only 2026-11-03 (lokal, tidak di repo) |
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
| Frontend | React 19 + Vite + Tailwind 4 (dibekukan) | Sudah ada, satu maintainer; O-17 | rewrite FE / Svelte (ditolak) |

**Dependensi wajib dipin persis** (tanpa `nimble.lock`, dengan `deps-check` yang
memverifikasi hash tree): `mummy 0.4.8`, `nimcrypto 0.7.3`, `zippy 0.10.20`,
`webby 0.2.1`, `crunchy 0.1.11`, `nimsimd 1.3.2`, `db_connector` (commit pin).

---

## 3. Struktur repo

```text
badminton-match/
├── task                        # dispatcher POSIX (memanggil task.d/<target>.sh)
├── task.d/                     # satu berkas per target; tidak ada file bersama
├── config.nims                 # path modul; dipakai nimsuggest & nim c polos
├── deps.lock                   # pin versi toolchain & dependensi
├── apps/
│   ├── api/
│   │   ├── src/                # main.nim, server.nim, health.nim, auth_routes.nim,
│   │   │                       # live.nim, ratelimit.nim, community_context.nim,
│   │   │                       # routes_gen.nim (generated — jangan diedit)
│   │   ├── tests/              # security/, tenant/
│   │   └── Dockerfile
│   └── web/                    # React 19 + Vite + Tailwind 4 (stack dibekukan)
├── modules/                    # 9 domain, tiap modul punya permukaan api.nim
│   ├── session/                # domain/ infrastructure/ tests/ api.nim
│   ├── player/
│   ├── rating/
│   ├── tournament/
│   ├── achievement/
│   ├── share/
│   ├── community/              # komunitas, anggota, undangan, pengaturan
│   ├── platform/               # config, idempotency, audit log
│   └── account/                # OIDC, sesi, role
├── packages/
│   ├── contracts/openapi/      # core.yaml + community.yaml (ditulis tangan)
│   │                           # api.yaml = hasil gabungan (generated)
│   └── web-client/             # TS client hasil generate
├── shared/platform-lib/        # logger, metrics, clock, uuidv7, sha256, db binder
├── db/
│   ├── migrations/             # 0001…0005, hanya lewat tools/dbtools
│   └── seeds/                  # platform_config.sql (L1)
├── tools/
│   ├── dbtools/                # migrate/verify/seed
│   ├── archcheck/              # aturan impor + pemindai literal angka bisnis
│   ├── contract-gen/           # spec → route Nim + client TS
│   ├── mock-api/               # server tiruan dari spec
│   ├── parity/                 # recorder + replayer + normalizer
│   ├── fixtures/               # data sintetis v1 deterministik
│   ├── oidc-stub/              # IdP palsu untuk E2E/CI
│   ├── ownerseed/              # bootstrap platform_owner + komunitas pertama
│   ├── rehearsal/              # latihan deploy/rollback
│   ├── import/                 # ETL bm → bm2
│   └── soak/                   # uji beban
├── ops/                        # dev/, caddy/, env/, scripts/, systemd/, webhook/
├── e2e/                        # Playwright: fungsional + a11y + visual
├── testdata/parity/            # korpus v1 dan v2
└── docs/                       # ops/ (runbook), handbook/, plan/, audits/
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

**Keputusan: database baru `bm2` di instance PostgreSQL yang sama. `bm` nol DDL.**

Bukan schema tambahan di dalam database `bm`: database terpisah memberi isolasi nyata
pada backup, hak akses, ledger migrasi, dan restore. Role aplikasi baru (`bm2_app`)
tidak memiliki akses ke `bm`. Satu instance, dua database, nol jalur silang.

**Batas komunitas (O-13…O-16).** Setiap tabel domain punya `community_id NOT NULL`.
PK tetap surrogate (`id`). FK yang **kedua kolomnya NOT NULL** memakai pasangan
komposit `(community_id, id)` sehingga baris tidak bisa merujuk entitas komunitas
lain bahkan bila kode lupa memfilter (batasannya di butir 11). Setiap UNIQUE ikut
di-scope: `(community_id, slug)`, `(community_id, alias_key)`,
`(community_id, match_key)`, dan seterusnya. Index operasional selalu berawalan
`community_id`.

Tabel platform: `platform.community`, `platform.user` (global),
`community.membership` (user × community × role), `community.invite`,
`community.settings`. Peran disimpan per keanggotaan; `platform_owner` global
hanya untuk membuat komunitas.

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
   `code_hash`, `created_at`, `revoked_at`, `expires_at`. Satu tautan hidup per
   sesi, read-only, bisa dicabut dan dirotasi. Tidak ada kolom `kind` karena tidak
   ada tautan tulis (O-9).
5. Kode akses **hash-only**, satu kunci bertipe per query; tidak ada
   `share_code = $1 OR id::text = $1`.
6. Seed poin memakai `ON CONFLICT DO NOTHING` (menggantikan `000023` yang menimpa
   tuning operator).
7. Semua waktu: `timestamptz` UTC untuk instan, `date` WIB untuk tanggal kalender —
   satu konvensi, ditegakkan test.
8. `view_code` unik **global**, bukan per komunitas: `/s/{code}` tidak membawa slug,
   jadi kode harus bisa diresolusi tanpa konteks. Kode acak ≥128 bit; charset
   alfanumerik seperti v1 (`handler/session.go:543-556`), bukan pola baru yang
   menolak kode lama.
9. Poin dihitung per komunitas: `rating_events`/`rating_deltas`/`rating_players`
   membawa `community_id`; window dan best-N dievaluasi di dalam komunitas itu.
10. Query builder menolak query tanpa predikat `community_id` pada tabel domain
    (gagal di test, bukan menghasilkan daftar kosong).
11. **FK komposit hanya untuk kolom NOT NULL.** PostgreSQL memakai `MATCH SIMPLE`:
    bila salah satu kolom FK bernilai NULL, constraint dilewati sepenuhnya. Karena
    itu relasi opsional (`rating_events.session_id` vs `tournament_id`,
    `game_players.replaced_player_id`) **tidak** memakai FK komposit; integritasnya
    dijaga `CHECK` + trigger + test, dan `community_id`-nya tetap NOT NULL.
12. Database dev lokal bernama `bm2_dev`; setiap worker mendapat **database sendiri**
    (`bm2_<agent>`) yang dikloning dari `bm2_template` — bukan schema tambahan,
    karena schema per worker akan bertabrakan dengan schema domain (`community`,
    `session`, …). Semua tooling menolak nama database yang tidak berawalan `bm2_`.

**Migrasi:** nomor urut, `schema_version` + checksum, dua fase untuk destruktif
(`expand` → backfill → `contract`), DDL hanya lewat `tools/dbtools`. App
**menolak start** bila migrasi tertunda atau checksum drift.

---

## 4A. Konfigurasi berlapis (tanpa angka bisnis di kode)

Tiga lapisan, dan hanya satu yang boleh berisi angka bisnis:

| Lapis | Isi | Disimpan di | Boleh diubah tanpa deploy |
|-------|-----|-------------|---------------------------|
| **L0 — invarian** | status HTTP, nama kolom, algoritma kripto, urutan SQL | kode | tidak (memang harus) |
| **L1 — default platform** | nilai awal semua parameter | `platform.config` | ya |
| **L2 — override komunitas** | penyesuaian per komunitas, dibatasi plafon L1 | `community.settings` | ya |

**Resolusi nilai:** `L2 → L1 → error`. Tidak ada lapis ketiga berupa konstanta di kode.
Bila key wajib tidak ada di kedua lapis, server **menolak start** (sama seperti migrasi
tertunda). Ini mencegah "default tersembunyi" yang membuat perilaku berbeda antara
lokal dan produksi.

**Registry key** (satu sumber, dipakai loader, validator, admin UI, dan test):

```text
key, tipe (int|decimal|bool|string|json), default, min, max, scope
(platform|community), deskripsi, sejak versi
```

**Cache & invalidasi:** tabel `platform.config_version` menyimpan satu counter.
Setiap tulis menaikkannya dalam transaksi yang sama; proses menyimpan snapshot
immutable dan memuat ulang saat counter berubah. Tidak ada TTL misterius, tidak ada
restart.

**Batas aman:** nilai komunitas divalidasi terhadap plafon L1. `platform_owner` bisa
menaikkan plafon; `owner` komunitas tidak.

**Contoh angka v1 yang wajib pindah ke config** (semua terverifikasi di kode):

| Nilai sekarang | Lokasi v1 | Key |
|---|---|---|
| ticker ingest 30 menit | `apps/api/cmd/server/main.go:149` | `ingest.ticker_minutes` |
| pagination granular 100 | `apps/api/internal/handler/granular.go:35` | `api.page_size_default` |
| papan peringkat 200 | `apps/api/internal/handler/ratings.go:193` | `rank.board_limit` |
| band 8-tier (1000–2100+) | `apps/api/internal/domain/rating_config.go:88-92` | `rating.tier_bands` |
| turnamen tepat 16 pair | `apps/api/internal/domain/tournament.go:61` | `tournament.classic.pair_count` |
| window 12 minggu, best 10, base 250 | seed `000018` | sudah config; pindahkan ke registry |

**Penegakan:** `tools/archcheck` memindai literal numerik di `modules/*/domain` dan
`apps/api/src`; setiap literal yang cocok dengan key registry menggagalkan build,
kecuali ada di allowlist L0 (`allowlist_constants.txt`) dengan alasan tertulis.

---

## 5. API

- Permukaan v2: **60 operasi**. Hitungan per kelompok, bukan klaim:

  | Kelompok | v1 | v2 | Perubahan |
  |---|---|---|---|
  | System & auth | 5 | **7** | `-` `/metrics` publik, `-` `/admin/verify`; `+` `auth/start`, `auth/callback`, `auth/logout`, `auth/me` |
  | Sessions | 16 | **13** | `-` `/watch`, `/events`, `POST /{id}/delete`; `PUT /sessions/{id}` → `PUT /{id}/schedule` |
  | Share | 0 | **3** | semua baru: `POST`/`DELETE /sessions/{id}/share`, `GET /s/{code}` |
  | Realtime | 0 | **3** | `WS /ws/c/{slug}/sessions/{id}`, `WS /ws/share/{code}`, `POST /c/{slug}/sessions/{id}/ws-ticket` |
  | Players | 7 | **8** | `PATCH /tier` + `PATCH /name` dilebur, `+` merge di path pemain |
  | Tournaments | 6 | **6** | `-` `PATCH /tournaments/{id}`, `+` `PATCH .../matches/{id}` |
  | Rankings & ratings | 14 | **10** | 4 route admin digabung ke path resource |
  | **Subtotal** | **48** | **50** | |
  | Komunitas & config | 0 | **10** | buat/daftar komunitas, buat/terima undangan, daftar anggota, ubah peran, keluarkan anggota, pengaturan, config, direktori |
  | **Total** | 48 | **60** | |

  Daftar final dibekukan di T-008a/T-008b; angka `60` adalah acceptance T-009.
- Konvensi: camelCase, RFC 9457 `problem+json` dengan `code` + `i18nKey`,
  pagination cursor, `Idempotency-Key` + hash body, `ETag`/`If-Match`
  (**412** bila basi, 428 bila tidak dikirim), batas ukuran body per route.
- **Semua route komunitas ber-prefix `/c/{slug}/…`.** Middleware me-resolve
  slug → `community_id` **sebelum** handler; slug tidak dikenal atau user bukan
  anggota → 404 (bukan 403, agar keberadaan komunitas tidak bocor). Tautan publik
  `/s/{code}` tidak memakai slug: kode itu sendiri yang menentukan komunitas.
  `Idempotency-Key` di-scope per komunitas.
- **Proxy same-origin (ADR-021).** FE tetap di `majadu.vercel.app`; browser tidak
  pernah memanggil `api.qouver.com` untuk HTTP. `vercel.json` me-rewrite
  `/api/:path*` → `https://api.qouver.com/:path*`, sehingga cookie sesi menjadi
  **first-party** dan `SameSite=Lax` sah. API sendiri **tidak** memakai prefix
  `/api`; prefix itu hanya ada di sisi FE. WebSocket tidak melewati proxy: klien
  memakai `wss://api.qouver.com/ws/...` dengan tiket sekali pakai (lihat §6).
- OpenAPI **ditulis tangan** dalam dua berkas: `packages/contracts/openapi/core.yaml`
  (auth, session, share, player, rating, achievement, tournament) dan
  `community.yaml` (komunitas, config, direktori). `./task contract-gen` menggabungkan
  keduanya menjadi `api.yaml` (artefak generated, tidak diedit tangan) lalu
  menghasilkan kerangka route Nim + client TS. CI gagal bila hasil generate berbeda
  dari commit.
- Tidak ada shim Go. Overlap memakai deploy berpasangan: v1 tetap hidup sebagai
  jalur rollback sampai v2 dinyatakan stabil.

Detail per-route ada di `memos/04-api-contract.md`; ringkasan tabel final masuk
`docs/handbook/features-and-routes.md` saat implementasi.

---

## 6. Realtime

WebSocket di `wss://api.qouver.com/ws/c/{slug}/sessions/{sessionId}` dan
`ws/share/{viewCode}`. Kanal sesi mewarisi `community_id` dari slug; kanal share
mengambilnya dari kode.

**Auth WebSocket = tiket, bukan cookie** (ADR-021). Handshake lintas site tidak
dapat diandalkan membawa cookie (Safari memblokir cookie pihak ketiga), jadi:

1. Klien memanggil `POST /c/{slug}/sessions/{id}/ws-ticket` lewat proxy HTTP
   (first-party, cookie sah) dan menerima `{ticket, expiresIn: 60}`.
2. Klien membuka `wss://api.qouver.com/ws/...?ticket=<opaque>`.
3. Server memvalidasi tiket (HMAC, sekali pakai, terikat ke sesi + principal +
   `community_id`), lalu menghapusnya. Tiket kedaluwarsa atau dipakai dua kali → 401.
4. Tiket hanya memberi akses **kanal itu**; tidak ada tiket yang bisa dipakai
   untuk menulis. Menulis tetap lewat HTTP dengan cookie.

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
- Endpoint: `GET /auth/google/start` → 302 ke Google; `GET /auth/google/callback`
  → tukar code, set cookie, 302 ke aplikasi; `POST /auth/logout`; `GET /auth/me`.
  Tidak ada endpoint yang menerima ID token dari JavaScript.
- `state`, `nonce`, `code_verifier` disimpan sebagai **hash** di `auth.oauth_flows`;
  cookie hanya `flow_id` (`__Host-bm_oauth`, 10 menit).
- ID token: `iss`/`aud`/`azp`/`exp`/`nonce`/`email_verified`, `sub` = kunci akun.
- Sesi: cookie opaque 32 byte, hash-only di DB, `__Host-`, `HttpOnly`, `Secure`,
  `SameSite=Lax`; absolut 30 hari, idle 14 hari; revoke satu transaksi dengan
  perubahan role.
- **Topologi (ADR-021, O-22):** FE tetap `majadu.vercel.app`; HTTP lewat rewrite
  proxy same-origin `/api/*` di Vercel. Cookie karena itu **first-party** untuk
  `majadu.vercel.app`, sehingga `SameSite=Lax` dan `__Host-` tetap sah dan tidak
  perlu `SameSite=None`. Origin yang diizinkan (`https://majadu.vercel.app`,
  `http://localhost:5173`) disimpan di config `security.allowed_origins`, bukan
  literal. API harus mempercayai header proxy Vercel (`X-Forwarded-For`) agar rate
  limit memakai IP asli — daftar proxy tepercaya ikut di config.
- **Tidak ada** access/refresh token Google yang disimpan, tidak ada token di JS.

### 7.2 Verifikasi ID token (ADR-009 diterima)

Memo 01 menyimpulkan "nimcrypto tanpa RSA → validasi klaim saja lewat TLS".
Memo 02 mensyaratkan "RS256 only, JWKS `kid`". Pemilik memilih yang kedua.

**Keputusan:** verifikasi tanda tangan RS256 lewat **OpenSSL `EVP_DigestVerify*`**.
Catatan hasil verifikasi: wrapper bawaan Nim (`lib/wrappers/openssl.nim`)
**hanya** mengekspos `EVP_DigestSignInit`/`EVP_DigestSignFinal` — tidak ada
`EVP_DigestVerify*`, tidak ada `RSA_new`/`BN_bin2bn`/`EVP_PKEY_assign_RSA`.
Jadi ini **modul binding lokal ±80–120 baris** (`importc` ke `libcrypto`) dengan
test vektor dari JWKS Google, dimiliki task T-084.
Karena `libcrypto` dimuat lewat `dynlib`, build **tidak** akan gagal saat library
absen. Karena itu verifikasi dilakukan saat boot: coba `dlopen` + satu vektor uji
tanda tangan; bila gagal, proses menolak start (bukan turun diam-diam ke mode
klaim-saja). Image runtime wajib menyertakan `libcrypto` dan ini diuji di job image.

### 7.3 Otorisasi & kapabilitas

| Kapabilitas | Siapa |
|-------------|-------|
| Baca sesi via tautan | pemegang `view_code` (read-only) |
| Tulis skor | sesi login Google, peran `host`+ |
| Buat sesi/turnamen | `host`+ |
| Merge/rename/delete pemain, tier | `admin`+ |
| Rebuild/revert/ingest | `admin`+ |
| Kelola role | `owner` **di komunitas itu** |
| Ikut serta di komunitas | `member` (baca papan, klaim profil sendiri, tanpa tulis admin) |
| Akses data lintas komunitas | tidak ada — 404 |

### 7.4 Remediasi P0/P1

| Temuan | Ditutup oleh |
|--------|--------------|
| IDOR `share_code` | `view_code` read-only, hash-only, list tanpa kode; menulis wajib sesi login |
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
| Kebocoran lintas komunitas | `community_id` wajib + FK komposit + 404 untuk entitas komunitas lain |

### 7.5 Selama P0 masih terbuka (v1 produksi)

**Keputusan pemilik (O-8): risiko diterima apa adanya.** Tidak ada hotfix Go dan
**tidak ada kontrol kompensasi** di edge. Ini pilihan sadar, bukan kelalaian, dan
dicatat di `ADR-011` beserta alasan serta cara mencabutnya bila berubah pikiran.

Konsekuensi yang harus diketahui:

- `GET /sessions` dapat dienumerasi siapa pun sampai API Nim rilis.
- Siapa pun yang memegang `share_code` dapat mengubah skor sesi draft.
- Sesi anonim dapat memicu ingest poin lewat auto-lock.

Tidak ada deteksi, tidak ada pembatasan, tidak ada pemantauan tambahan. Satu-satunya
mitigasi adalah kecepatan rilis R1.

---

## 8. Build, CI/CD, operasional

**Build:** satu sumber flag di `./task build`:
`-d:release --opt:speed --threads:on --mm:atomicArc`. Nim 2.4.0 dipin di CI,
Dockerfile (tarball + sha256), dan `.nimble`. `-static` ditolak (libpq dynlib).

Dua aturan build yang wajib, karena kalau tidak, kerja paralel rusak:

1. **`nimcache` per worktree.** Nim mengunci cache berdasarkan *nama file proyek*,
   bukan path (`compiler/options.nim:1000-1018`), sehingga empat worktree yang
   membangun `apps/api/src/main.nim` berbagi `~/.cache/nim/main_r`. `./task` wajib
   menetapkan `--nimcache:$repoRoot/.cache/<worktree>`.
2. **`serverThreads` = ukuran pool.** Mummy default `countProcessors()*10`
   (`mummy.nim:1476`) dan menjalankan handler di thread itu (`:464-480`). Pool DB
   yang lebih kecil dari jumlah thread menghasilkan 503 saat beban normal. Pool
   dihitung dari `serverThreads`, bukan angka tetap.

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

Delapan metrik yang wajib ada (nama tetap, dipakai dashboard dan test):

| Metrik | Tipe | Kenapa |
|---|---|---|
| `http_requests_total{route,method,status}` | counter | laju & tingkat error |
| `http_request_duration_seconds{route}` | histogram | p95 |
| `db_pool_in_use` / `db_pool_waiting` | gauge | pool < `serverThreads` terlihat langsung |
| `ws_watchers{community}` | gauge | mendekati batas 50/sesi |
| `ingest_lag_seconds` | gauge | ticker ingest macet |
| `janitor_rows_deleted{table}` | counter | retensi benar-benar berjalan |
| `build_info{version,commit}` | gauge | versi yang benar-benar hidup |
| `db_size_bytes` | gauge | pertumbuhan tak wajar |

Tanpa alert otomatis pada tahap ini: pembacaan manual lewat listener internal, dan
`/readyz` dipakai deploy.

**Backup & restore (O-23):** `pg_dump` harian untuk `bm` dan `bm2`, retensi 7 hari,
disimpan di disk VPS dengan mode 600. Sebelum setiap impor atau migrasi destruktif,
dump tambahan wajib dibuat dan diverifikasi bisa dibaca (`pg_restore --list`).
Latihan restore masuk T-063 dengan target < 30 menit; hasilnya dicatat.

**Deploy berpasangan (FE + API):** kontrak berubah, jadi FE dan API naik bersama.
`index.html` dikirim `Cache-Control: no-store`; aset ber-hash dan immutable. Rollback
mengembalikan **keduanya**, bukan hanya image API. Urutan dan perintahnya ada di
`docs/ops/cutover.md` (T-065), dan skripnya tidak boleh mengubah satu sisi saja.

---

---

### 8.1 Versioning & rilis (ADR-020, O-24)

**Satu sumber versi:** berkas `VERSION` di root (`MAJOR.MINOR.PATCH[-prerelease]`).
Tidak ada nomor versi yang ditulis tangan di kode, `package.json`, atau Dockerfile.
`./task build` meneruskan `-d:AppVersion`, image menerima `--build-arg VERSION`,
dan nilai yang benar-benar hidup terlihat di `GET /version` serta metrik
`build_info{version,commit}`.

**Skema:** SemVer 2.0. Tag berformat `vX.Y.Z` (**SSH-signed annotated**, bukan
lightweight). Rilis pra-rilis memakai `vX.Y.Z-rc.N`.

**Rilis pertama: `2.0.0`** (O-25). Angka ini menandai generasi kedua aplikasi
(backend Nim + multi-komunitas), bukan kelanjutan nomor v1. Karena `major ≥ 1`
sejak awal, tidak ada fase 0.x: aturan di bawah langsung berlaku.

**Aturan kenaikan**, dihitung dari Conventional Commits sejak tag terakhir
(`feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `chore`, `build`, `ci`):

| Kondisi | Kenaikan |
|---|---|
| ada `!` pada tipe atau footer `BREAKING CHANGE:` | **major** |
| ada `feat` | **minor** |
| sisanya (`fix`, `perf`, …) | **patch** |

`auto` memakai tabel ini. Bump eksplisit (`patch|minor|major`) tetap diizinkan,
tetapi `./task release` menolak menurunkan versi dan menolak bump yang lebih kecil
dari hasil `auto` (mis. `patch` saat ada `feat`) kecuali diberi `--force` dengan
alasan yang dicatat di CHANGELOG.

**Alur `./task release`:**

```text
./task release patch|minor|major|auto [--pre rc] [--push] [--dry-run]
```

1. Tolak bila: tree kotor, bukan di `main`, tag tujuan sudah ada, `main` tertinggal
   dari `origin/main`, atau gate `./task ci` gagal.
2. Hitung versi berikutnya (atau pakai bump eksplisit; `auto` memakai tabel di atas).
3. Untuk `--pre`: naikkan `N` bila inti versi sama dengan pra-rilis terakhir,
   selain itu mulai dari `rc.1`. Promosi pra-rilis = jalankan tanpa `--pre` dengan
   inti versi yang sama.
4. Tulis `CHANGELOG.md`: bagian baru di atas, dikelompokkan
   **Breaking / Added / Changed / Fixed / Security**, tiap entri menyebut commit
   dan path yang terdampak. Perubahan pada `db/migrations/` wajib muncul sebagai
   catatan migrasi.
5. Perbarui `VERSION`, commit `chore(release): vX.Y.Z`, buat annotated tag dengan
   isi catatan rilis yang sama, lalu tanda tangani: `git tag -s` (SSH, `gpg.format
   ssh`, kunci yang sama dengan commit). Workflow menolak tag tanpa tanda tangan valid.
6. `--dry-run` mencetak versi + catatan tanpa menulis apa pun. Tanpa `--push`,
   perintah berhenti dan mencetak dua perintah push; tidak ada push implisit.
7. `--push` mendorong commit ke `main` **dan** tag. Commit ke `main` memicu deploy
   (ref-guard), jadi `--push` hanya dipakai setelah R4 dan setelah gate rilis lolos.

**GitHub Release:** workflow `.github/workflows/release.yml` terpicu tag `v*`,
`permissions: contents: write`, `timeout-minutes: 15`, cache Nim/pnpm. Isinya:
verifikasi tanda tangan tag, verifikasi tag = isi `VERSION`, jalankan test, buat
GitHub Release memakai catatan dari annotated tag (`gh release create`), dan
lampirkan **digest image** (tidak ada binary terpisah). Tidak ada tag yang dibuat
oleh workflow — tag selalu berasal dari `./task release`, sehingga riwayat rilis
bisa direproduksi lokal.

**Yang tidak boleh:** tag dari UI GitHub, `npm version`, atau mengubah `VERSION`
manual tanpa `./task release`; nomor versi di dua tempat; rilis tanpa catatan.

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
reset `TRUNCATE` urut FK, guard nama DB wajib berawalan `bm2_`.

Gate: `./task check` ≤ 60 s · `./task verify <module>` ≤ 5 min · `./task ci` ≤ 20 min.

---

## 10. Migrasi & cutover (ADR-022, O-10)

Model: **cutover instan**. Satu push ke `main` = v2 live. Tidak ada masa
berdampingan, tidak ada dua versi yang melayani trafik bersamaan. Konsekuensinya
dipakai untuk merancang urutannya.

1. R0–R3 berjalan lokal; v1 tetap di produksi tanpa perubahan.
2. Rehearsal deploy di host lokal (binary + PostgreSQL lokal): build, restart,
   health gagal, rollback. Container hanya bila runtime-nya ada.
3. **Pra-impor, saat v1 masih melayani.** Di VPS: siapkan database `bm2` + role
   `bm2_app` → migrasi → seed L1 + bootstrap (`platform_owner`, komunitas default)
   → ETL dari `bm` (baca saja) → rekonsiliasi. `bm` tidak pernah ditulis. Bootstrap
   wajib lebih dulu: T-096 menolak start tanpa key L1, dan ETL butuh `community_id`
   tujuan.
   ETL boleh diulang selama v1 masih hidup; setiap ulangan menghapus dan membangun
   ulang data `bm2` dari snapshot terbaru.
4. **Satu push.** `main` memicu build + restart v2. Setelah `/readyz` hijau dan
   smoke lulus, v1 tidak lagi dilayani. Push adalah titik tak bisa kembali untuk
   *trafik*, bukan untuk data: `bm` utuh.
5. Poin **dihitung ulang** dari event, bukan disalin; snapshot v1 dipakai sebagai
   fixture verifikasi.
6. Seluruh data v1 dipetakan ke **satu komunitas default**; slug-nya ditentukan saat
   impor dan dicatat di `platform.import_row_map`.
7. Tautan `/s/{code}` lama **tidak dipertahankan**: kode baru diterbitkan per sesi,
   karena format dan cakupan kode v1 tidak bisa dijamin sama. Komunikasi ke pengguna
   adalah bagian dari runbook.
8. **Rollback** = restart image `:prev` (v1) dan arahkan Caddy kembali; `bm` utuh,
   data yang ditulis ke `bm2` setelah cutover dibuang. Rollback hanya tersedia
   selama image v1 masih ada — karena itu T-082 menunggu 14 hari observasi.
9. Jendela kehilangan data: baris yang ditulis ke `bm` antara langkah 3 dan 4 tidak
   ikut terimpor. Pra-impor dijalankan sedekat mungkin dengan push, dan selisihnya
   dicatat di runbook (`docs/ops/cutover.md`).

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
| ADR-002 | Database `bm2` baru, `bm` nol DDL | diterima (memo 03) |
| ADR-003 | WebSocket, bukan SSE | diterima (memo 01/04) |
| ADR-004 | Kontrak ditulis tangan + codegen | diterima (memo 04) |
| ADR-005 | Binder SQL wajib | diterima (memo 01) |
| ADR-006 | Google OIDC untuk semua penulis; tautan hanya baca | diterima (O-3, O-9) |
| ADR-007 | Parity harness + divergensi deklaratif | diterima (memo 06) |
| ADR-008 | Tanpa shim Go, cutover berpasangan | diterima (memo 04) |
| ADR-009 | Verifikasi RS256 via modul binding OpenSSL (`EVP_DigestVerify*` belum ada di wrapper Nim) | diterima (O-12) |
| ADR-010 | Peran `member` | diterima: R2 (O-11) |
| ADR-011 | P0 diterima terbuka tanpa hotfix dan tanpa kontrol kompensasi | diterima (O-8), dengan konsekuensi tertulis di §7.5 |
| ADR-012 | Multi-komunitas: satu skema, `community_id` + FK komposit, poin per komunitas, akun global | diterima (O-13..O-16) |
| ADR-013 | Frontend React 19 + Vite + Tailwind 4 dibekukan | diterima (O-17) |
| ADR-014 | Parameter bisnis berlapis di DB (`platform.config` → `community.settings`), tanpa default di kode | diterima (O-18, O-19) |
| ADR-015 | Auth memakai Authorization Code + PKCE; tidak ada ID token yang dikirim dari JavaScript | diterima (§7.1) |
| ADR-016 | Identitas publik = `id` UUIDv7; tidak ada `public_id` terpisah | diterima (memo 03 vs 04) |
| ADR-017 | `view_code` unik global agar `/s/{code}` bisa diresolusi tanpa komunitas | diterima (§4 butir 8) |
| ADR-018 | Akun dinonaktifkan + dianonimkan; riwayat rating dipertahankan (`ON DELETE RESTRICT` tetap) | diterima (AUTH-10) |
| ADR-019 | ~~FE dan API satu site~~ | **digantikan ADR-021** (O-22 berubah: FE tetap di Vercel) |
| ADR-020 | SemVer dari Conventional Commits, versi tunggal di `VERSION`, tag annotated, GitHub Release dari tag | diterima (O-24) |
| ADR-021 | FE tetap di `majadu.vercel.app`: HTTP lewat rewrite proxy same-origin + WebSocket auth tiket sekali pakai | diterima (O-22) |
| ADR-022 | Cutover instan: pra-impor ke `bm2` saat v1 hidup, lalu satu push; tanpa masa berdampingan | diterima (O-10) |
