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
8. **Tidak ada notifikasi keluar di 2.0.0** (O-42): tidak ada email, push, atau
   webhook ke pengguna. Admin melihat antrean join/klaim saat membuka aplikasi.
9. **Dokumen dibekukan setelah R0** (O-43). Setelah walking skeleton lulus,
   perubahan hanya lewat OpenAPI, `testdata/authz/matrix.yaml`, dan baris backlog.

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

**Format `deps.lock`** (dibaca T-002, T-011, T-072): satu baris per entri,
`name version source sha256`, komentar diawali `#`, header berisi `tree <sha256>`
dari gabungan baris yang diurutkan. Entri juga mencakup alat non-Nim yang dipakai
gate: versi Nim, Playwright, browser, dan font. `./task deps-check` menghitung
ulang tree dari isi yang benar-benar terpasang dan gagal bila berbeda; ia tidak
membandingkan timestamp.

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

**Aturan kode yang ditegakkan mesin** (bukan konvensi; semuanya menggagalkan
`./task check`):

| Aturan | Penegak | Alasan |
|---|---|---|
| `{.push raises: [].}` per modul; `except Exception` hanya di satu boundary handler | `nim check` + grep | `except Exception` di Mummy (`mummy.nim:466-472`) menelan `IndexDefect`; bug jadi 500 yang tidak menggagalkan test |
| Tidak ada `discard` atas hasil DB; update wajib `execUpdate(): int` dan `== 1` | `archlint` + grep | `tryExec(): bool` membuang pesan error; `getRow` 0 baris mengembalikan string kosong (`db_postgres.nim:464-474`) |
| `case` atas enum tanpa `else`; tidak ada `else: discard` | `nim check` (exhaustiveness) + archlint | `else` mengembalikan nilai kosong secara senyap |
| Batas: 400 baris/berkas, 60 baris/proc, CC ≤ 10, nesting ≤ 4, ≤ 6 parameter | `tools/archcheck` (opsional sampai ada kode) | menjaga review tetap mungkin; bukan gate R0 |
| Test hanya lewat `expectProblem(status, code)` / asersi bertipe | archlint pada `tests/` | `.status == 200` telanjang lolos untuk alasan yang salah |
| Satu parser `?`→`$1` (`bind.nim`); tidak ada rewriter kedua | archlint | `dbFormatImpl` sudah merusak `jsonb ?`; duplikat parser = dua bug |
| Shell: `shellcheck` SC2310/SC2311, helper `fail()` | CI job Shell | `trap ERR` tidak menyala di dalam `if ! cmd` |
| Identitas kolom SQL dari enum, bukan string | archlint | binder mengikat nilai, bukan identifier |

### 3.1 Kontrak `./task`

- `./task <target> [args...]` → `exec sh "$REPO_ROOT/task.d/<target>.sh" "$@"`.
  Target tak dikenal → cetak daftar target, exit 2.
- **Nama target = nama berkas** (tanpa pengecualian): `check.sh`, `build.sh`,
  `test.sh`, `verify.sh`, `ci.sh`, `dev-db.sh`, `contract-gen.sh`, `deps-check.sh`,
  `mock-api.sh`, `coverage.sh`, `release.sh`.
- Env yang dijamin: `REPO_ROOT`; `WORKTREE` = basename root + 8 karakter sha256
  path (disanitasi); `NIMCACHE_CHECK=$REPO_ROOT/.cache/$WORKTREE/check`;
  `NIMCACHE_BUILD=$REPO_ROOT/.cache/$WORKTREE/build`.
- Semua skrip `set -eu`; error lewat `fail()`; `trap ERR` tidak diandalkan (lihat
  §8). Exit 0 hanya bila seluruh langkah lulus.
- `check` = format + `nim check` + archcheck + unit (< 60 s). `verify <module>` =
  build + test modul itu dengan DB. `ci` = check + build + seluruh test + contract
  check. `.cache/` dan `nimcache/` masuk `.gitignore` (dimiliki T-018).

### 3.2 `config.nims`

```nim
switch("path", thisDir() & "/shared")
switch("path", thisDir() & "/modules")
switch("path", thisDir() & "/apps")
switch("path", thisDir() & "/tools")
switch("threads", "on")
switch("mm", "atomicArc")
switch("stackTrace", "on")
switch("lineTrace", "on")
```

`thisDir()` dipakai, bukan `$projectDir` (yang menunjuk direktori entrypoint,
`apps/api/src`). `-d:release --opt:speed` hanya ditambahkan oleh `./task build`,
supaya `nim check` polos tetap cepat dan tetap memakai konfigurasi yang sama.

---

## 4. Data

**Keputusan: database baru `bm2` di instance PostgreSQL yang sama. `bm` nol DDL (O-20).**

Bukan schema tambahan di dalam database `bm`: database terpisah memberi isolasi nyata
pada backup, hak akses, ledger migrasi, dan restore. Role aplikasi baru (`bm2_app`)
tidak memiliki akses ke `bm`. Satu instance, dua database, nol jalur silang.

**Batas komunitas (O-13, O-14, O-15, O-16).** Setiap tabel domain punya `community_id NOT NULL`.
PK tetap surrogate (`id`). FK yang **kedua kolomnya NOT NULL** memakai pasangan
komposit `(community_id, id)` sehingga baris tidak bisa merujuk entitas komunitas
lain bahkan bila kode lupa memfilter (batasannya di butir 11). Setiap UNIQUE ikut
di-scope: `(community_id, alias_key)`, `(community_id, match_key)`, dan seterusnya —
**kecuali** identitas global yang memang lintas komunitas.

**Dua pengecualian yang tidak boleh di-scope** (round-4 DB review):

- `platform.community.slug` — unik **global**. `UNIQUE(community_id, slug)` akan
  menghapus keunikan slug dan membuat dua komunitas bisa memakai slug yang sama.
- `platform.user.email_hash`, `platform.user.google_sub` — global, karena satu akun
  Google dipakai di semua komunitas (COM-09).

Tabel platform: `platform.community`, `platform.user` (global),
`community.membership` (user × community × role), `community.invite`,
`community.join_request`, `community.settings`. Peran disimpan per keanggotaan; `platform_owner` global
hanya untuk membuat komunitas.

### 4.1 Invarian DDL yang wajib ada di migrasi

Round-4 menemukan beberapa invarian yang hanya ditulis sebagai niat, bukan DDL.
Semuanya masuk `0001`/`0004`/`0005` dan diverifikasi `dbtools verify`:

| # | Invarian | Alasan |
|---|---|---|
| D1 | `platform.community` dan `platform.user` dibuat di **`0001`**, bukan `0004` | `0001` sudah memuat FK `community_id` ke `platform.community`; urutan sekarang mustahil dijalankan di DB kosong |
| D2 | `UNIQUE (community_id, id)` pada **setiap parent** yang dirujuk FK komposit: `session.sessions`, `player.players`, `rating.events`, `tournament.tournaments`, `tournament.matches` | PostgreSQL menolak FK ke kolom yang bukan unique; tanpa ini semua FK komposit gagal dibuat |
| D3 | Index anak `(community_id, <parent>_id)` untuk setiap FK komposit | FK komposit tidak memakai index PK; tanpa ini join/scan jadi seq scan |
| D4 | `session.links.community_id NOT NULL` + FK komposit `(community_id, session_id)` | AAD enkripsi menyebut `community_id`; tanpa kolomnya ciphertext tidak bisa diikat ke komunitas |
| D5 | `session.links.id` **tanpa** `DEFAULT`; `expires_at` **tanpa kedaluwarsa otomatis** (boleh NULL, hanya dicabut) | id yang terisi default setelah insert membuat AAD tidak deterministik; O-35 memilih tautan hidup sampai dicabut |
| D6 | Index parsial `session.links (session_id) WHERE revoked_at IS NULL` (unik) | satu tautan hidup per sesi; `now()` tidak boleh masuk predikat index (tidak immutable) |
| D7 | `community.join_request`: unik parsial `(community_id, user_id) WHERE status = 'pending'` + `CHECK ((status = 'pending') = (decided_at IS NULL))` | unik polos memblokir pengajuan ulang setelah ditolak; CHECK mencegah baris "pending" yang sudah diputuskan |
| D8 | `platform.cutover_state` **singleton**: `id boolean PRIMARY KEY CHECK (id)` — satu baris saja | `/readyz` tidak boleh ambigu bila ada dua baris |
| D9 | `platform.ws_ticket`: `channel_kind text CHECK (channel_kind IN ('session','share'))`, `channel_id uuid NOT NULL`, `user_id uuid NULL`, `CHECK (channel_kind = 'share' OR user_id IS NOT NULL)` | tiket anonim hanya boleh membuka kanal `share`; kolom `channel` teks bebas tidak bisa dijaga FK |
| D10 | `platform.import_row_map` PK `(community_id, source_table, source_key)` | ETL ulang setelah komunitas default dibuat ulang tidak boleh melewati semua baris |
| D11 | `player.players.canonical_key` = normalisasi nama (generated column) + `UNIQUE (community_id, canonical_key)`; `user_id` unik parsial `WHERE user_id IS NOT NULL` | nama mentah menghasilkan duplikat; unique `user_id` polos gagal saat merge dua pemain yang sudah diklaim |
| D12 | `auth.oauth_flows` dikonsumsi dengan `DELETE … RETURNING` sebelum tukar `code` | callback yang diputar ulang harus gagal, bukan membuat sesi kedua |
| D13 | `account.audit` menyimpan **allowlist** field (`actor_id`, `actor_role`, `community_id`, `action`, `target_kind`, `target_id`, `result`, `reason`, `request_id`, `before`/`after` hanya untuk kolom yang diizinkan per aksi); tidak ada kode share, ciphertext, email, atau IP mentah | audit paling sering dibaca saat insiden; tanpa `actor_role` aksi `platform_owner` tidak bisa dibedakan, tanpa `reason` keputusan klaim/merge tidak bisa dipertanggungjawabkan |
| D16 | `account.audit` **append-only** di level grant: `bm2_app` hanya `INSERT, SELECT`; retensi `audit.retention_days` terpisah dari `janitor.retention_days`, dan pembersihannya lewat job CLI dengan role `bm2_owner` (bukan aplikasi) | audit yang bisa diubah aplikasi bukan bukti; retensi 7 hari untuk data sementara tidak boleh menghapus jejak insiden; audit juga tidak boleh tumbuh tanpa batas |
| D14 | Tabel domain yang memuat kredensial (`session.links`, `community.invite`, `platform.ws_ticket`) menyimpan **hash** untuk pencarian dan ciphertext/opaque untuk nilai asli; `invite` memakai `token_hash bytea UNIQUE`, tanpa kolom token plaintext | plaintext di DB membatalkan alasan enkripsi; undangan adalah bearer token yang setara kode share |
| D15 | `player.claims`: `status ∈ (pending, approved, rejected, released)`, `decided_at`/`decided_by`/`reason` NULL hanya saat `pending`; unik parsial `(community_id, player_id) WHERE status='pending'` dan `(player_id) WHERE status='approved'`; `player.merge_log` append-only (`source_id`, `target_id`, `rows_moved`, `actor_id`, `created_at`) | satu klaim menunggu per pemain; satu pemilik disetujui; pelepasan harus menutup klaim `approved` **dalam transaksi yang sama**, kalau tidak index parsial menolak klaim berikutnya; merge harus bisa ditelusuri |

`rating.deltas` memakai `ON DELETE RESTRICT` di kedua sisi (butir 2), sehingga
penghapusan turnamen/sesi wajib menghapus `deltas` → `events` → induk dalam satu
transaksi dengan urutan eksplisit; ini diuji sebagai kasus negatif (T-006b).

| Kriteria | 1:1 `bm` | Evolve `bm` | **Redesign `bm2`** |
|----------|----------|-------------|--------------------|
| Risiko ke prod | rendah | tinggi | rendah |
| Biaya migrasi | nol | sedang | tinggi (sekali) |
| Utang v1 ikut | ya | sebagian | tidak |
| Kerja paralel | sulit | sedang | mudah |

Alasan memilih redesign: `DeletePlayer` menghapus riwayat pemain lain, `Save()`
mereset `version` lewat delete+insert, `share_code OR id::text` mematikan PK, dan
tanggal kalender bercampur dengan instan tanpa aturan konversi yang diuji. Semuanya
hanya bisa dibetulkan dengan mengubah bentuk tabel.

**Perbaikan yang masuk desain:**

1. `session.games` upsert dengan `UNIQUE(session_id, round_no, court_no)` + trigger
   `version`; tidak ada delete+insert (juga menyelamatkan `fix_matches.slot_*`).
2. `rating.deltas` FK `ON DELETE RESTRICT` — hapus pemain tidak boleh menghapus
   delta pemain lain.
3. Index riil: `player_achievements(achievement_key)`,
   `sessions(community_id, session_date DESC, updated_at DESC)`,
   `rating_events(community_id, local_date DESC)`,
   `rating_deltas(event_id, side, player_id)`, `tournament_matches(pair_a_id)`,
   `tournament_matches(pair_b_id)`, `membership(user_id)`; hapus 6 pasang index duplikat.
   Tidak ada index yang predikatnya memakai `now()`.
4. `session.links` (satu nama untuk tabel ini): `community_id`, `id`,
   `session_id`, `code_hash`, `code_enc`, `key_id`, `created_by`, `created_at`,
   `revoked_at`, `expires_at` (NULLable, **tidak diisi otomatis** — O-35: tautan
   hidup sampai dicabut). Satu tautan hidup per sesi, read-only, bisa dicabut dan
   dirotasi. Tidak ada kolom `kind` karena tidak ada tautan tulis (O-9).
5. Kode akses disimpan **dua bentuk** (ADR-025): `code_hash` (SHA-256) untuk
   verifikasi, dan `code_enc` untuk ditampilkan ulang. Format `code_enc` baku:
   `versi(1) || nonce(12) || ciphertext || tag(16)`, AES-256-GCM dengan
   **AAD = community_id || session_link_id** sehingga ciphertext tidak bisa
   dipindah antar-baris. Kunci disimpan sebagai map di env `SHARE_CODE_KEYS`
   (`{"1":"<base64-32B>","2":"…"}`) + `SHARE_CODE_ACTIVE_KEY_ID`; boot **gagal**
   bila kunci aktif tidak ada. CLI rotasi mendekripsi dengan `key_id` lama lalu
   mengenkripsi ulang dengan kunci aktif; **nonce wajib baru** untuk setiap
   enkripsi (CSPRNG), dan baris yang `key_id`-nya sudah kunci aktif **dilewati**.
   Tanpa dua aturan itu, menjalankan rotasi dua kali memakai ulang nonce dengan
   kunci yang sama — keystream dan tag autentikasi bisa dipulihkan. Idempoten
   berarti "aman diulang", bukan "boleh memakai nonce lama".
   Menampilkan ulang lewat `GET /c/{slug}/sessions/{id}/share`, wajib `host`+,
   menulis audit (aktor, link, waktu), dan dibatasi rate limit. Tidak ada
   plaintext di DB; parameter/path yang memuat kode diredaksi dari log.
   Satu kunci bertipe per query; tidak ada `share_code = $1 OR id::text = $1`.
6. Seed poin memakai `ON CONFLICT DO NOTHING` (menggantikan `000023` yang menimpa
   tuning operator).
7. Semua waktu: `timestamptz` UTC untuk instan; `date` adalah **tanggal kalender
   di zona komunitas** (`community.settings.timezone`, default `Asia/Jakarta`),
   bukan WIB yang di-hardcode. API mengirim instan sebagai RFC 3339 UTC (`Z`).
   Dump v1 berisi 27 kolom `timestamptz`, **nol** `timestamp without time zone`, dan
   8 kolom `date`; jadi yang diuji adalah konversi `date` → instan pada batas hari
   di zona komunitas. Image runtime wajib memuat `tzdata`; tanpa itu konversi jatuh
   diam-diam ke UTC. `date` yang sudah ada di v1 dianggap WIB saat ETL.
   ETL **membangkitkan UUIDv7 baru** untuk setiap baris (v1 memakai
   `DEFAULT gen_random_uuid()` = v4) dan mencatat pasangan lama→baru di
   `platform.import_row_map`, supaya ADR-016 tidak dilanggar oleh data impor.
8. `view_code` unik **global**, bukan per komunitas: `/s/{code}` tidak membawa slug,
   jadi kode harus bisa diresolusi tanpa konteks. Kode dibangkitkan ≥128 bit
   (base62, ~22 karakter) — bukan meniru generator v1 yang hanya ~59,5 bit
   (`handler/session.go:543-556`). Tautan v1 tidak dipertahankan (O-10), jadi tidak
   ada kebutuhan kompatibilitas charset.
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

**Dev DB lokal (O-5, O-6, O-7):** PostgreSQL yang sudah berjalan di mesin ini; tidak
ada container; tidak ada push sampai R4.

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
menaikkan plafon; `admin` komunitas tidak.

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

**Key operasional (bukan angka bisnis) yang tetap wajib ada di registry**, karena
kalau tidak, nilainya akan menjadi konstanta tersembunyi di kode:
`security.max_body_bytes`, `security.max_json_depth`, `security.read_timeout_ms`,
`security.join_request_rate`, `security.share_scrape_limit`,
`ws.max_watchers_per_session`, `ws.max_watchers_per_ip`, `ws.max_watchers_process`,
`ws.ticket_ttl_seconds`, `ws.session_ttl_minutes`, `session.absolute_days`,
`session.idle_days`, `auth.flow_ttl_minutes`, `janitor.retention_days`,
`audit.retention_days`.
Semuanya di-scope `platform`; komunitas hanya boleh menurunkannya bila ada plafon.

### 4B. Kontrak akses database (dipakai T-004, T-006, T-043)

- **Placeholder selalu `$1..$n`.** Tidak ada rewriting `?` → `$n` sama sekali;
  archlint menolak `?` di dalam string SQL. Ini menghapus satu parser dan seluruh
  bug `jsonb ?` yang pernah muncul di v1.
- Tipe parameter: `null | text | int64 | bool | uuid | timestamp` (timestamp
  selalu UTC). `NULL` dikirim sebagai parameter NULL dan dibaca lewat
  `pqgetisnull`; tidak pernah menjadi `""`.
- Permukaan modul `shared/platform-lib/db`:
  - `query(db, sql, params): seq[Row]`
  - `queryOne(db, sql, params): Option[Row]`
  - `execUpdate(db, sql, params): int` — jumlah baris; pemanggil wajib memeriksa
    `== 1` untuk mutasi yang menargetkan satu baris.
  - `tx(db, body: proc(tx: DbConn): T): T` (generik atas `T`) — `BEGIN`/`COMMIT`/`ROLLBACK`.
- Error: `DbError` membawa `sqlState`, `constraint`, dan `message`; pemetaan
  `23505` → 409 dilakukan di layer route, bukan di driver.
- Pool: tepat `workerThreads` koneksi (T-004), checkout timeout dari config.
- Tidak ada `discard` atas `execUpdate`/`query*`; dilanggar = build gagal (T-010).

### 4C. Dev database (T-007)

- DSN dari env `MAJADU_PG_DSN` (dev: `postgresql://$USER@127.0.0.1:5432/bm2_dev`).
- Tiga role dibuat `ops/dev/pg-up.sh` dengan password dev dari `.env.local`
  (gitignored): `bm2_owner` (DDL), `bm2_app` (DML), `bm2_etl` (baca staging,
  tulis `bm2` hanya saat ETL).
- `bm2_template` dibuat dengan menjalankan migrasi sebagai `bm2_owner`; worker
  memakai `CREATE DATABASE bm2_<agent> TEMPLATE bm2_template`.
- `bm2_app` dan `bm2_etl` **tidak** diberi `CONNECT` ke `bm` (O-41).

## 5. API

- Permukaan v2: **73 operasi** (O-2). Hitungan per kelompok, bukan klaim:

  | Kelompok | v1 | v2 | Perubahan |
  |---|---|---|---|
  | System & auth | 5 | **9** | 3 route sistem tersisa; `-` `/metrics` publik, `-` `/admin/verify`; `+` `auth/start`, `auth/callback`, `auth/logout`, `auth/me`, `GET` + `DELETE /auth/sessions` |
  | Sessions | 16 | **13** | `-` `/watch`, `/events`, `POST /{id}/delete`; `PUT /sessions/{id}` → `PUT /{id}/schedule` |
  | Share | 0 | **4** | semua baru: `POST`/`DELETE /sessions/{id}/share`, `GET /c/{slug}/sessions/{id}/share`, `GET /s/{code}` |
  | Realtime | 0 | **4** | `WS /ws/c/{slug}/sessions/{id}`, `WS /ws/share/{code}`, `POST /c/{slug}/sessions/{id}/ws-ticket`, `POST /s/{code}/ws-ticket` |
  | Players | 7 | **12** | `PATCH /tier` + `PATCH /name` → satu `PATCH /{id}`; `+` merge; `+` ajukan/daftar/putuskan/lepas klaim; `stats` & `achievements` di path pemain |
  | Tournaments | 6 | **6** | `-` `PATCH /tournaments/{id}`, `+` `PATCH .../matches/{id}` |
  | Rankings & ratings | 14 | **11** | 4 route admin digabung ke path resource; papan punya dua pintu: `/c/{slug}/rankings` (anggota) dan `/s/{code}/rankings` (penonton) |
  | **Subtotal** | **48** | **59** | |
  | Komunitas & config | 0 | **14** | buat/daftar komunitas, gabung, buat/terima undangan, ajukan join, daftar pengajuan, putuskan pengajuan, daftar anggota, ubah peran, keluarkan anggota, pengaturan, config, direktori |
  | **Total** | 48 | **73** | |

  Empat operasi klaim: `POST /c/{slug}/players/{id}/claims` (ajukan),
  `GET /c/{slug}/players/{id}/claims` (antrean + riwayat),
  `PATCH /c/{slug}/players/{id}/claims/{claimId}` (keputusan `admin`), dan
  `DELETE /c/{slug}/players/{id}/claim` (lepas klaim sendiri; `admin` boleh
  melepas klaim siapa pun dengan alasan). Pelepasan **bukan** `DELETE` baris:
  status `approved` menjadi `released`, `player.user_id` dikosongkan, audit
  `player.claim.released`, dalam satu transaksi.

  Path di tabel ditulis tanpa prefix. Route komunitas memakai `/c/{slug}` di
  depannya; pengecualiannya `/s/{code}`, `POST /s/{code}/ws-ticket`, dan
  `/s/{code}/rankings`, yang sengaja tidak membawa slug. Daftar final dibekukan di
  T-008a/T-008b; angka `73` adalah acceptance T-009.
- Konvensi: camelCase, RFC 9457 `problem+json` dengan `code` + `i18nKey`,
  pagination cursor, `Idempotency-Key` + hash body, `ETag`/`If-Match`
  (**412** bila basi, 428 bila tidak dikirim), batas ukuran body per route.
  Semua instan ditulis RFC 3339 UTC dengan sufiks `Z`; tanggal kalender `YYYY-MM-DD`.
- **Tidak ada identifier dinamis yang diinterpolasi.** `sort`, `order`, `filter`,
  dan nama kolom hanya boleh berasal dari enum tertutup yang tercantum di kontrak;
  nilai lain → 400. Binder SQL hanya mengikat **nilai**; identitas kolom dipilih
  lewat `case` atas enum, bukan string dari klien. `archcheck` menolak pemanggilan
  SQL yang argumennya bukan literal atau query builder bertipe.

**`Ctx` eksplisit, tanpa threadvar** (dipakai T-003, T-009, T-092):

```nim
type Ctx* = object
  requestId*: string
  userId*: Option[UserId]
  communityId*: Option[CommunityId]
  role*: Role          # none|member|host|admin|platform_owner
  clientIp*: string
  now*: DateTime       # dari MAJADU_NOW; now() dilarang di modules/apps
```

Handler menerima `Ctx` + input hasil parse. Tidak ada state global/thread-local,
sehingga handler aman dijalankan di thread Mummy mana pun.
- **Semua route komunitas ber-prefix `/c/{slug}/…`.** Middleware me-resolve
  slug → `community_id` **sebelum** handler; slug tidak dikenal atau user bukan
  anggota → 404 (bukan 403, agar keberadaan komunitas tidak bocor). **Papan
  peringkat tidak punya pintu publik tanpa kode** (O-32, ADR-027): anggota membuka
  `/c/{slug}/rankings` (404 bila bukan anggota), penonton membuka
  `/s/{code}/rankings`. Satu tautan yang bocor karena itu tidak membuka roster
  komunitas bagi orang yang tidak memegang kode. Tautan publik `/s/{code}` tidak
  memakai slug: kode itu sendiri yang menentukan komunitas.
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
- Tidak ada shim Go dan **tidak ada masa berdampingan** (ADR-022, ADR-031).
  Cutover dijalankan **manual** lewat `ops/scripts/cutover.sh` (O-39); deploy dari
  push tidak pernah memicunya. Rollback memakai `:v1-final` yang dipertahankan
  30 hari (O-29), dan hanya `rollback.sh` yang menyalakan kembali v1.

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
3. Server memvalidasi tiket (sekali pakai, terikat ke kanal + principal +
   `community_id`), lalu menghapusnya. Tiket kedaluwarsa atau dipakai dua kali → 401.
   Penyimpanan: tabel `platform.ws_ticket` (`token_hash`, `channel_kind`,
   `channel_id`, `user_id`, `community_id`, `expires_at`), dikonsumsi dengan satu
   `DELETE … RETURNING` sehingga balapan dua upgrade hanya menghasilkan satu
   pemenang. Tidak ada tiket di memori proses. `channel_kind` ∈
   `('session','share')`; `channel_id` adalah uuid (`session.id` atau
   `session.links.id`) — bukan slug atau kode mentah. `user_id` wajib untuk
   `session`, NULL hanya untuk `share` (dijaga `CHECK`, D9).
4. **Penonton tanpa login** memakai `POST /s/{code}/ws-ticket` (tanpa cookie,
   dibatasi per kode + per IP, hanya kanal `share`). Tiket tetap sekali pakai.
5. Tiket hanya memberi akses **kanal itu**; tidak ada tiket yang bisa dipakai
   untuk menulis. Menulis tetap lewat HTTP dengan cookie.
6. **Pencabutan menutup socket dan membuang tiket.** Logout, perubahan peran,
   penghapusan anggota, dan rotasi tautan menulis event yang menutup koneksi
   terkait **dan** menghapus **semua** `ws_ticket` milik principal itu
   (`WHERE user_id = $1`), bukan hanya kanal yang sedang diubah; tiket yang terbit
   sebelum pencabutan tidak bisa dipakai lagi. Untuk kanal `share`, penghapusan
   memakai `channel_kind='share' AND channel_id=$1`. Tidak menunggu TTL 60 detik.
7. Handshake memeriksa `Origin` terhadap `security.allowed_origins`; tiket di
   query string **tidak boleh** dicatat di access log (logger meredaksi parameter
   `ticket`).

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
  → tukar code, set cookie, 302 ke aplikasi; `POST /auth/logout`;
  `GET /auth/me`; `GET /auth/sessions`; `DELETE /auth/sessions` (mencabut semua
  sesi **lain** milik akun dan menghapus tiket WS-nya).
  Tidak ada endpoint yang menerima ID token dari JavaScript.
- **Flow sekali pakai, dikonsumsi secara atomik.** Callback menjalankan
  `DELETE FROM auth.oauth_flows WHERE flow_id = $1 RETURNING …` **sebelum** menukar
  `code` ke Google. Replay callback karena itu gagal 400 tanpa membuat sesi kedua,
  dan `flow_id` tidak pernah dipakai sebagai id sesi. `GET` callback tetap lolos
  gerbang CSRF hanya karena cookie `__Host-bm_oauth` mengikat flow ke browser. (D12)
- **Redirect URI wajib lewat proxy:** `https://majadu.vercel.app/api/auth/google/callback`
  (prod) dan `http://localhost:5173/api/auth/google/callback` (dev). Kalau callback
  didaftarkan di `api.qouver.com`, cookie `__Host-bm_oauth` di-set pada host yang
  berbeda dari host callback sehingga flow selalu gagal — dan pelonggaran
  pengecekan cookie akan menjadi login CSRF. Karena itu callback **harus** satu
  host dengan halaman login.
- `return_to` disimpan di `auth.oauth_flows` saat `start` dan divalidasi **dua kali**
  (saat start dan saat callback): hanya path yang cocok
  `^/[A-Za-z0-9._~!$&'()*+,;=:@%/-]*$`, tanpa `..`, tanpa `//`, tanpa `\`, dan
  tanpa encoding ganda (`%2F%2F`). Selain itu → 400. Test open-redirect di T-070
  mencakup `//evil`, `/\evil`, `%2F%2Fevil`, dan `https://evil`.
- `state`, `nonce`, `code_verifier` disimpan sebagai **hash** di `auth.oauth_flows`;
  cookie hanya `flow_id` (`__Host-bm_oauth`, 10 menit).
- ID token: `iss`/`aud`/`azp`/`exp`/`nonce`/`email_verified`, `sub` = kunci akun.
- Sesi: cookie opaque 32 byte, hash-only di DB, `__Host-`, `HttpOnly`, `Secure`,
  `SameSite=Lax`; absolut 30 hari, idle 14 hari; revoke satu transaksi dengan
  perubahan role; `GET /auth/sessions` menampilkan sesi aktif (perangkat, IP
  terakhir, waktu), `DELETE /auth/sessions` mencabut semua sesi lain sekaligus.
- **Tanpa step-up** (O-37). Aksi sensitif (tampilkan tautan, ubah peran, merge,
  putuskan klaim) tidak meminta login ulang; kontrol penggantinya adalah daftar
  sesi + revoke-all, audit wajib untuk setiap aksi, dan rotasi tautan sebagai
  operasi normal. Konsekuensi yang diterima: sesi 30 hari yang dicuri bisa
  melakukan aksi admin sampai dicabut; ini dicatat di §7.5.
- **Topologi (ADR-021, O-22):** FE tetap `majadu.vercel.app`; **seluruh** lalu lintas
  HTTP, termasuk callback OAuth, lewat rewrite proxy same-origin `/api/*` di Vercel.
  Cookie karena itu **first-party** untuk `majadu.vercel.app`, sehingga
  `SameSite=Lax` dan `__Host-` sah tanpa `SameSite=None`. Origin yang diizinkan
  (`https://majadu.vercel.app`, `http://localhost:5173`) disimpan di config
  `security.allowed_origins`, bukan literal.
- **IP ditentukan di Caddy, bukan di aplikasi.** Aplikasi selalu melihat peer
  loopback, jadi ia **tidak** mempercayai `X-Forwarded-For` sama sekali; ia membaca
  satu header `X-Client-IP` yang **ditulis** Caddy. Caddy menghitungnya dari
  `X-Forwarded-For` hanya bila peer ada di daftar `trusted_proxies` (rentang Vercel
  yang dipublikasikan, diisi saat deploy), dan membuang header kiriman klien.
  Listener WebSocket langsung juga lewat Caddy, jadi aturannya sama; tidak ada
  listener yang mempercayai header dari luar. `Host` tidak dipakai untuk keputusan
  keamanan. Test: XFF palsu dari peer non-proxy → `X-Client-IP` = IP peer.
- **Tidak ada** access/refresh token Google yang disimpan, tidak ada token di JS.
- **Bahasa (O-21):** seluruh UI berbahasa Inggris; teks diambil dari kunci i18n,
  tidak ada string Inggris yang ditanam di komponen.

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

**Jebakan yang sudah diuji di mesin ini (round-6 Nim review).** Nama generik
`libcrypto.dylib` **meng-abort proses saat load** (`SIGABRT`, "loading libcrypto
in an unsafe way"), bahkan bila keg `openssl@3` ada di
`DYLD_FALLBACK_LIBRARY_PATH`; tidak ada berkas `/usr/lib/libcrypto*.dylib` di
macOS modern dan `/usr/bin/openssl` adalah LibreSSL 3.3.6. Konsekuensinya
boot-check **tidak bisa** mendeteksi kesalahan nama library — proses sudah mati
sebelum `main`. Karena itu:

- soname ditulis eksplisit sejak awal: `libcrypto.3.dylib` (macOS, keg
  `openssl@3`) dan `libcrypto.so.3` (Debian bookworm), bukan `libcrypto.dylib`
  generik;
- `EVP_PKEY_assign_RSA` **adalah makro**, bukan simbol; binding memakai
  `EVP_PKEY_assign(pkey, 6, rsa)` (NID RSA = 6), dan daftar simbol diverifikasi
  dengan `nm -gU libcrypto.3.dylib` sebelum menulis `importc`;
- boot-check menuntut `OpenSSL_version(0)` berawalan `"OpenSSL 3"` **dan**
  memanggil `EVP_DigestVerifyUpdate` pada vektor uji;
- dev macOS menyetel `DYLD_FALLBACK_LIBRARY_PATH` ke keg `openssl@3`; tanpa itu
  `libpq` dan `libcrypto` tidak ditemukan saat runtime.

**Pengambilan JWKS dibatasi, bukan sekadar "cache".** URL adalah konstanta
`https://www.googleapis.com/oauth2/v3/certs` (tidak dari header, tidak dari `iss`),
TLS memverifikasi peer (`CVerifyPeer`, CA bawaan image), redirect **ditolak**
(`maxRedirects = 0`), ukuran respons dibatasi `security.jwks_max_bytes`, dan `kid`
tak dikenal hanya memicu **satu** refetch per 60 detik (sisanya 401). Tanpa aturan
ini JWKS menjadi jalur SSRF/refetch tak terbatas dan penyerang bisa memaksa
verifikasi lambat.

### 7.3 Otorisasi & kapabilitas

Model peran (ADR-023, O-26): **satu peran global + tiga peran komunitas**. Tidak ada
`owner` per komunitas; kata "owner" hanya untuk level platform.

| Kapabilitas | `member` | `host` | `admin` | `platform_owner` |
|---|---|---|---|---|
| Baca papan & riwayat sendiri; **ajukan** klaim profil | ya | ya | ya | ya, **jika sudah bergabung** (default `member`) |
| Lihat riwayat & badge sendiri | ya | ya | ya | ya |
| Buat/ubah sesi & turnamen | — | ya | ya | ya |
| Terbitkan/rotasi tautan, lock/approve | — | ya | ya | ya |
| **Lepas klaim sendiri** (pemain yang diklaimnya) | ya | ya | ya | ya, jika pernah mengklaim sebagai `member` |
| **Putuskan/lepas klaim pemain lain** (setujui/tolak/release, alasan wajib) | — | — | ya | ya |
| Merge pemain, rebuild/revert poin | — | — | ya | ya |
| Kelola anggota, peran, undangan, putuskan pengajuan join | — | — | ya | ya |
| Pengaturan komunitas & override dalam plafon | — | — | ya | ya |
| Buat/hapus komunitas, angkat admin, ubah L1 & plafon | — | — | — | ya |
| Aksi **manajemen** di komunitas yang belum diikuti (pengaturan, peran, hapus) | — | — | — | ya (audit setiap aksi) |
| Baca data domain komunitas yang belum diikuti | — | — | — | tidak — 404; harus join dulu |

**Klaim pemain tidak pernah langsung mengikat** (O-33, ADR-028). `member` mengajukan
klaim → baris `player.claims` berstatus `pending`; `admin` menyetujui (mengisi
`user_id`, menutup klaim lain) atau menolak. Pengajuan ganda untuk pemain yang sama
saat masih pending ditolak 409. Pemain hasil anonimisasi (AUTH-10) memakai jalur
yang sama, sehingga tidak ada jendela "siapa cepat dia dapat" setelah akun pergi.
Merge hanya `admin`, menulis `account.audit` **dan** `player.merge_log` (pemain
sumber, tujuan, jumlah baris riwayat yang pindah, aktor, waktu).

**Pelepasan klaim (O-38, ADR-030).** Pemilik klaim melepas klaimnya sendiri lewat
`DELETE /c/{slug}/players/{id}/claim` (tanpa body; alasan tetap `self_released`).
`admin` melepas klaim orang lain lewat aksi `release` pada
`PATCH /c/{slug}/players/{id}/claims/{claimId}` dengan `reason` wajib. Keduanya:

- mengambil `SELECT … FOR UPDATE` pada baris `player` **dan** klaim `approved`
  lebih dulu, lalu menulis dengan `UPDATE … WHERE id=$claim AND status='approved'
  AND user_id=$subject RETURNING …`; bila 0 baris → 409 (bukan 500);
- mengubah klaim `approved` → `released` (`decided_by`, `decided_at`, `reason`),
  `player.user_id` → NULL, dan menulis audit `player.claim.released`
  (`target_kind='claim'`, `after={player_id,status,subject_user_id}`) dalam
  transaksi yang sama.

**`admin` tidak boleh memutuskan klaimnya sendiri** (`decided_by = claimant` →
403); pada komunitas dengan satu admin, klaimnya harus diputuskan admin lain atau
`platform_owner`. **Tidak ada masa tunggu**: akun Google mana pun — termasuk email
berbeda — boleh mengajukan klaim baru, tetapi tetap `pending` sampai `admin`
menyetujui. Yang mencegah serah-terima riwayat secara diam-diam bukan waktu,
melainkan persetujuan admin, riwayat `released` di antrean, dan audit dua
peristiwa. Riwayat rating tetap milik `player`, tidak ikut akun.

Hanya **satu** akun `platform_owner` aktif (O-31); menambah akun kedua lewat CLI dengan
audit, bukan lewat UI. Pengguna biasa masuk lewat undangan **atau** pengajuan join
yang diputuskan `admin` komunitas (O-30); undangan terikat email (O-34). Pengajuan
ganda yang masih pending dijawab `202` identik (`ON CONFLICT DO NOTHING`), bukan
409, supaya status tidak membocorkan keberadaan komunitas.

`platform_owner` **tidak otomatis** menjadi anggota komunitas mana pun, tetapi
**boleh bergabung** sebagai anggota biasa (`member`) lewat `POST /c/{slug}/join`
tanpa undangan; setiap join menulis audit. Ini perlu supaya platform owner bisa ikut
bermain dan mengklaim profil.

Bypass global hanya berlaku untuk **aksi manajemen** (pengaturan komunitas, peran,
hapus, konfigurasi) dan setiap aksinya menulis audit dengan
`actor_role = 'platform_owner'`. **Baca data domain** (pemain, sesi, poin,
turnamen) tetap membutuhkan keanggotaan: tanpa join, hasilnya 404 seperti pengguna
lain. Ini menghapus ambiguitas "boleh baca semua" yang bertabrakan dengan uji
cross-tenant.

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

### 7.6 Tautan baca, log, dan audit

Round-4 red team menemukan bahwa jalur kebocoran utama bukan di app, melainkan di
**proxy**: seluruh HTTP lewat `vercel.json`, jadi Vercel mencatat path
`/api/s/<code>` di log request-nya. Konsekuensinya:

- **Header wajib pada setiap respons yang memuat kode** (`GET /s/{code}`, `GET
  /s/{code}/rankings`, `POST /s/{code}/ws-ticket`, `POST`/`DELETE
  /c/{slug}/sessions/{id}/share` yang mengembalikan kode, dan halaman FE-nya):
  `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, `X-Robots-Tag:
  noindex, nofollow`. `no-store` juga wajib untuk `/auth/me`, `/auth/sessions`,
  dan seluruh `/c/*` (respons berisi identitas dan peran; cache bersama tidak
  boleh menyimpannya). Ini dipasang di **API dan** `apps/web/vercel.json` — Caddy
  saja tidak cukup karena FE dan proxy ada di Vercel. API **tidak** mengirim
  `Access-Control-Allow-Origin` sama sekali; browser tidak pernah memanggil API
  lintas-origin untuk HTTP.
- **Rotasi tautan mencabut seketika.** Karena `no-store`, tidak ada salinan edge
  yang bisa menyajikan kode mati. Rotasi diperlakukan sebagai operasi normal
  (satu klik, ber-audit), bukan tindakan darurat; masa berlaku tidak dipakai
  sebagai pengganti pencabutan (O-35).
- **Log tidak memuat kode.** Logger aplikasi meredaksi segmen path `/s/<kode>` dan
  parameter `ticket`; Caddy melakukan hal yang sama; log Vercel tidak bisa
  dikendalikan dari repo, jadi kode diperlakukan sebagai rahasia berumur pendek
  yang rotasinya murah — bukan rahasia permanen.
- **Audit memakai allowlist field** (D13): tanpa kode, ciphertext, email, atau IP
  mentah; nilai panjang di-escape dan dipotong.
- **Metrik tidak berlabel identitas.** Label hanya `route` (template, mis.
  `/s/{code}`), `method`, `status`, `table`; tidak ada slug, kode, `user_id`, atau
  `community_id`. Ini mencegah dashboard menjadi daftar komunitas.
- **Batas input:** `security.max_body_bytes` per route, `security.max_json_depth`,
  dan `security.read_timeout_ms` — nilainya di registry config (L1), bukan angka di
  kode; nilai awal disebut di seed, bukan di handler. Tanpa ini satu `PATCH` bertubuh besar
  bisa menjatuhkan proses dan menutup live semua komunitas.
- **Pengajuan join tidak membocorkan keberadaan komunitas:** jawaban untuk slug
  yang tidak ada, komunitas yang tidak menerima pengajuan, dan pengajuan yang
  sudah ada semuanya `202` dengan body identik; keputusan hanya terlihat oleh
  `admin`. Rate limit-nya dari `security.join_request_rate` (seed L1: per akun dan
  per IP), bukan konstanta di handler.
- **Tiket anonim dibatasi sebelum INSERT:** plafon per kode dan per IP diperiksa
  sebelum baris `ws_ticket` ditulis, bukan sesudah handshake.

---

## 8. Build, CI/CD, operasional

**Build:** satu sumber flag di `./task build`:
`-d:release --opt:speed --stackTrace:on --lineTrace:on --threads:on --mm:atomicArc`.
Nim 2.4.0 dipin di CI, Dockerfile (tarball + sha256), dan `.nimble`. `-static`
ditolak (libpq dynlib).

**Kontrak proses runtime:**

| Hal | Ketentuan |
|---|---|
| Port | env `MAJADU_PORT` (wajib; dev 8080). Tidak ada default di kode. |
| `GET /healthz` | 200 `{"status":"ok"}` selama event loop hidup; tidak menyentuh DB. |
| `GET /readyz` | 200 hanya bila DB terjangkau, migrasi terkini, dan `snapshot_sha256` cocok; selain itu 503 `problem+json`. |
| `GET /version` | 200 `{"version","commit"}` dari `-d:AppVersion` + build info. |
| Shutdown | SIGTERM/SIGINT → berhenti menerima, tidur `MAJADU_DRAIN_MS` (wajib; dev 5000), `server.close()`, exit 0; batas keras `MAJADU_SHUTDOWN_TIMEOUT_MS`. |
| Log | satu baris JSON ke stdout: `ts, level, msg, request_id, route, method, status, dur_ms`; tanpa kode/email/IP. |

Kedua nilai `MAJADU_*` adalah konfigurasi runtime proses (bukan angka bisnis),
disuplai `EnvironmentFile`; `T-001` menerima keduanya lewat env dan menolak start
bila `MAJADU_PORT` tidak ada.

Dua aturan build yang wajib, karena kalau tidak, kerja paralel rusak:

1. **`nimcache` per worktree, dua direktori.** Nim mengunci cache berdasarkan
   *nama file proyek*, bukan path (`compiler/options.nim:1000-1018`), sehingga
   beberapa worktree dengan nama proyek sama berbagi cache. `nim check` sendiri
   menulis 0 berkas dan `--nimcache` eksplisit **tidak** menambah suffix, tetapi
   `check` dan `build` yang bergantian pada satu direktori tetap memicu churn
   artefak. `./task` karena itu menetapkan dua direktori:
   `--nimcache:$repoRoot/.cache/<worktree>/check` dan `…/build`.
2. **`workerThreads` eksplisit = ukuran pool.** `ServerObj.serverThreads` privat
   (`mummy.nim:86`) tanpa accessor, default `countProcessors()*10`
   (`mummy.nim:1476`), dan di Linux `sysconf` mengabaikan kuota cgroup Podman.
   Rencana tidak bisa "membaca `serverThreads`" karena tidak ada API-nya. Jadi
   aplikasi menetapkan satu nilai eksplisit `workerThreads = N`, memakai N untuk
   `newServer(..., workerThreads = N)` **dan** ukuran pool, lalu mencetaknya di
   log + `build_info`. Pool yang lebih kecil dari N menghasilkan 503 saat beban
   normal; yang lebih besar memboroskan koneksi.

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
≤120 MB, digest reproducibility diuji, dan memuat `tzdata` (konversi tanggal
komunitas tidak boleh bergantung pada zona bawaan container).

**Alias staging.** Sebelum cutover, `staging.majadu.vercel.app` memakai **OAuth
client terpisah** (bukan client produksi) dan didaftarkan sebagai redirect URI
kedua, dipakai untuk memverifikasi `Set-Cookie` lewat proxy, login, dan satu alur
sesi. Alias ini stabil (bukan preview deployment). Saat cutover, alias, client
staging, dan redirect URI-nya **dihapus**; test memastikan `allowed_origins` hanya
berisi dua origin produksi/dev dan tidak ada client staging yang masih aktif.

**Deploy (`ops/scripts/deploy-vps.sh`)** wajib:

- ref-guard fail-closed, `fetch` + `reset --hard`;
- `flock -w 900` dan **`exit 1`** bila lock tidak didapat (bukan `exit 0`), plus
  `trap ERR` yang mencatat langkah yang gagal;
- **self re-exec**: bila script di repo berbeda dari yang berjalan, salin, lalu
  `exec` dirinya sendiri — supaya push yang memperkenalkan logika cutover tetap
  memakai logika baru pada push itu juga, bukan "berlaku deploy berikutnya";
- retensi `:local` dan `:prev`, ditambah **satu** tag `:v1-final` yang dikecualikan
  dari rotasi selama **30 hari** (amandemen eksplisit kontrak retensi, ADR-026); sebelum
  tag dihapus, image di-`podman save` ke tarball yang diarsipkan di luar rotasi;
- **deploy tidak pernah menjalankan cutover** dan tidak membaca berkas penanda apa
  pun. Cutover hanya `ops/scripts/cutover.sh` (O-39);
- **cutover manual (`ops/scripts/cutover.sh`, O-39)**: dijalankan sekali oleh
  operator lewat SSH, memakai `flock` yang sama dengan deploy. Guard: (a) menolak
  bila `cutover_state` sudah terisi ("already cut over"); (b) `:v1-final` dibuat
  **hanya bila belum ada** dan digest-nya diperiksa — resume tidak boleh menandai
  v2 sebagai v1-final; (c) menulis `cutover.step` per langkah dan menerima
  `--from <step>` untuk melanjutkan, bukan mesin resume otomatis;
  (d) `systemctl --user disable` unit v1 sebelum dump (bukan hanya stop), supaya
  reboot tidak menghidupkannya, dan `enable` kembali hanya lewat `rollback.sh`;
- gate `/readyz` (bukan `/healthz`) + `smoke.sh`;
- **tarik image**: `podman login ghcr.io` memakai token dari env (mode 600),
  `podman pull ghcr.io/hidaydev/badminton-match@sha256:…`, lalu tag `:local`;
  registry tak terjangkau → pakai `:prev` (v2 sebelumnya) tanpa menyentuh jaringan;
  `:v1-final` **hanya** dipakai oleh `rollback.sh`, supaya v1 tidak pernah hidup lagi
  dan menulis ke `bm` setelah cutover (O-41);
- `rollback.sh` mengembalikan image, env, dan snippet Caddy sekaligus, dengan
  `caddy validate` sebelum reload.

**Unit systemd (Quadlet)** wajib punya `StartLimitIntervalSec=300` +
`StartLimitBurst=5`, `MemoryMax=`, dan `OnFailure=majadu-alert.service` (unit
satu-baris yang menulis ke journal + memanggil webhook notifikasi). Tanpa itu
crash loop hanya mengisi disk tanpa alarm. `Restart=always` tetap, tetapi dibatasi
`StartLimit*` supaya tidak berputar selamanya.

**Ambang & rekonsiliasi ETL terlihat tanpa dashboard.** Delapan metrik berasal dari
app, sedangkan ETL berjalan **sebelum** app hidup. Karena itu cutover menulis
`cutover.step` + `cutover_state.rows_imported` per tabel, dan probe eksternal
(cron 1 menit di VPS) memeriksa: `/readyz` 200, `build_info` == `cutover_state.version`,
`rows_imported` == hitungan staging. Kegagalan memicu
`majadu-alert.service`; tidak ada dead-man timer berbasis dashboard.

**Image dibangun sekali (ADR-024).** Workflow rilis membangun image pada tag,
mendorongnya ke `ghcr.io/hidaydev/badminton-match:vX.Y.Z`, dan mencatat digest di
GitHub Release. Deploy menarik **digest itu** (bukan rebuild), lalu menandainya
`:local`. Build lokal hanya untuk dev dan untuk rollback darurat. Ini menghapus
kemungkinan dua image berbeda dengan versi yang sama.

Ini **amandemen sadar** terhadap kontrak `podman build` lokal di `AGENTS.md` §3:
unit tetap `Pull=never` karena image di-pull eksplisit oleh script (bukan oleh
`AutoUpdate`), `podman login ghcr.io` memakai token dari env mode 600, dan bila
registry tidak terjangkau rollback memakai `:v1-final` yang sudah ada di disk.

**Observability:** `/healthz` (proses), `/readyz` (DB + versi skema), metrics di
listener internal, log terstruktur tanpa PII, retensi 7 hari.

Delapan metrik yang wajib ada (nama tetap, dipakai dashboard dan test):

| Metrik | Tipe | Kenapa |
|---|---|---|
| `http_requests_total{route,method,status}` | counter | laju & tingkat error |
| `http_request_duration_seconds{route}` | histogram | p95 |
| `db_pool_in_use` / `db_pool_waiting` | gauge | pool < `workerThreads` terlihat langsung |
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
`restore.sh` menerima target `bm`, `bm2`, `bm2_*`, `bm_restore_*`, **dan
`bm_staging`** — tanpa pengecualian terakhir, guard yang dimaksudkan melindungi
justru memblokir satu-satunya langkah cutover yang membutuhkannya.

**Kehilangan env = tautan share mati permanen.** `SHARE_CODE_KEYS` hanya ada di
`/srv/qouver/apps/<app>/env/` (mode 600) tanpa salinan off-box (O-23 menerima risiko
disk yang sama). Konsekuensi ditulis di runbook: bila env hilang, `code_enc` tidak
bisa didekripsi dan tautan harus diterbitkan ulang. `prod.env.example` wajib memuat
`bm2_owner` dan `bm2_app` secara eksplisit agar role tidak "lupa rumah".

**Deploy berpasangan (FE + API):** kontrak berubah, jadi FE dan API naik bersama.
`index.html` dikirim `Cache-Control: no-store`; aset ber-hash dan immutable. Header
itu dipasang di `apps/web/vercel.json` (FE dilayani Vercel), bukan hanya di Caddy;
tanpa itu browser bisa memakai bundle v2 setelah rollback dan v1 tidak mengenal
`410 CLIENT_OUTDATED`. Rollback mengembalikan **keduanya**, bukan hanya image API.
Urutan dan perintahnya ada di `docs/ops/cutover.md` (T-065), dan skripnya tidak
boleh mengubah satu sisi saja. Konsekuensi rollback ditulis jujur di runbook:
data `bm2` setelah cutover hilang, sesi v2 tidak berlaku (semua pengguna login
ulang), dan tab yang masih memuat bundle v2 harus di-reload paksa.

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
sejak awal, aturan SemVer di bawah langsung berlaku tanpa fase pra-1.0.

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
`permissions: contents: write` hanya pada job rilis, `timeout-minutes: 15`, cache
Nim/pnpm, `allowed_signers` di-commit agar tanda tangan SSH bisa diverifikasi.
Isinya: verifikasi tanda tangan tag, verifikasi tag = isi `VERSION`, jalankan test,
bangun image, dorong ke GHCR, buat GitHub Release dengan catatan dari annotated tag
(`gh release create`), dan lampirkan **digest image** (tidak ada binary terpisah).
Tidak ada tag yang dibuat oleh workflow — tag selalu berasal dari `./task release`,
sehingga riwayat rilis bisa direproduksi lokal. **Urutan push tidak atomik, dan itu
disengaja:** tag didorong lebih dulu, `./task release` menunggu Release + digest
muncul (`gh release view`, timeout 10 menit), baru commit `main` didorong sehingga
deploy menarik digest yang sudah ada. Kalau workflow gagal, `main` tidak didorong
dan produksi tidak berubah.

**Exit criteria rilis (selain cutover):** rilis dinyatakan selesai hanya bila
keenam ini benar — (1) GitHub Release berisi digest image yang benar-benar
dideploy; (2) `build_info{version}` di produksi == tag; (3) `/readyz` hijau 24 jam
tanpa restart loop; (4) tidak ada error 5xx baru di log yang tidak ada di baseline;
(5) smoke login + satu sesi + satu share link lulus di produksi; (6) `:v1-final`
dijadwalkan penghapusan bertanggal (D+30) dan digest + tarball-nya diarsipkan
sebelum tag dihapus. Checklist ini hidup di `docs/ops/release.md` (T-107).

**Yang tidak boleh:** tag dari UI GitHub, `npm version`, atau mengubah `VERSION`
manual tanpa `./task release`; nomor versi di dua tempat; rilis tanpa catatan.

## 9. Testing

| Lapis | Isi | Target |
|-------|-----|--------|
| Unit | domain murni | < 5 s, domain ≥ 90% |
| Property | poin, generator, validasi skor, standings | 10k kasus/menit |
| Integrasi | DB nyata, satu binary per modul | gagal bila DB tak ada |
| Kontrak | OpenAPI ↔ handler ↔ client | generate bersih |
| Parity | golden JSON v1 vs v2 | **≥1 kasus per operasi** (73), < 90 s |
| E2E | alur host+guest, login, live | < 5 menit |
| A11y/visual | halaman inti (daftar eksplisit) | 0 violation |

**Parity harness** (lihat `memos/06`): capture sekali pada commit+dump ber-checksum.
Toleransi angka **nol**; fake clock `MAJADU_NOW` wajib sejak hari pertama.
Gate-nya bukan "80 kasus", melainkan **setiap operasi punya minimal satu kasus**
kontrak, ≥40% kasus berstatus ≥400, dan tidak ada kasus dengan `expect` kosong.
`/s/{code}/rankings` diuji sebagai property + fixture (jendela poin tidak bisa
diparitasikan karena capture memakai tanggal nyata), bukan dibiarkan tanpa kasus.

**Determinisme `state.json`:** hash per tabel tidak boleh memakai `created_at`
(`DEFAULT now()`) atau `id` acak. Setiap tabel mendeklarasikan proyeksi kolom tetap
dan `ORDER BY` eksplisit; kolom waktu diganti placeholder, UUID dipetakan ke alias
berurut. Lint SQL menolak `DEFAULT now()`/`CURRENT_TIMESTAMP` pada tabel korpus
parity — nilai itu tidak bisa difake karena `now()` = `transaction_timestamp()`.
Replayer mengirim `Accept-Encoding: identity` (Mummy meng-gzip body > 860 byte tanpa
`Vary`, yang membuat body capture tidak stabil).

**Matriks otorisasi adalah artefak**, bukan prosa: `testdata/authz/matrix.yaml`
berisi baris `route × role × keanggotaan × kepemilikan (self/other/none) → status`.
Dimensi kepemilikan wajib ada, karena tanpa itu `member` yang melepas klaim orang
lain akan lolos sebagai 200. Setiap route di kontrak wajib punya minimal satu
baris; route tanpa baris membuat `./task test` gagal. T-023 dan
T-094 membaca berkas yang sama, sehingga "matriks diuji" bisa gagal secara objektif.

**Coverage (O-36)** diukur `task.d/coverage.sh` dengan instrumentasi gcov
(`--passC:--coverage --passL:--coverage`), `gcovr`/`lcov` untuk laporan, dan
`coverage-baseline.json`; domain ≥ 90%, total ≥ 75%, gate gagal bila angkanya
turun. Nim **tidak** punya flag `--coverage` (diverifikasi lewat `nim --fullhelp`),
jadi acceptance yang menyebutnya harus diganti. Berkas tanpa baris terukur
(`LF = 0`) menggagalkan gate, supaya denominator tidak menyusut. `routes_gen.nim` dan berkas `*_gen` dikecualikan lewat daftar
eksplisit, dan ada test yang memastikan berkas generated **tidak** muncul di laporan
(dilarang `--ignore` yang terlalu luas).

**A11y/visual** mem-pin browser (versi Playwright di `deps.lock`) dan font
(disajikan lokal, bukan Google Fonts), `maxDiffPixels: 0`, dan daftar rute yang
diuji ditulis di `e2e/visual.routes.ts` — bukan "halaman inti" yang bisa ditafsirkan
ulang.

**Kompatibilitas FE ↔ API** diuji, bukan hanya diprosedurkan: `apps/web` mencatat
`apiVersion` minimum yang didukung, API menolak klien di bawahnya dengan
`410 Gone` + `code: CLIENT_OUTDATED`, dan E2E menjalankan bundle
terakhir terhadap API terakhir **dan** bundle sebelumnya terhadap API terakhir
(dua arah rollback yang realistis). Daftar browser yang didukung ditulis di
`e2e/browsers.ts` (Playwright project), bukan diasumsikan.

**Rehearsal menulis JSON durasi per langkah** (`tools/rehearsal/timings.json`);
gate T-063 membaca berkas itu, bukan stopwatch manual. `state.json` dan
`timings.json` keduanya artefak yang di-commit untuk baseline.
Divergensi sengaja dideklarasikan per kasus dan **harus tetap berbeda** — kalau Nim
malah identik dengan v1 pada kasus IDOR, test gagal.

Isolasi DB: `bm2_template` + `CREATE DATABASE … TEMPLATE` per worker (~300 ms),
reset `TRUNCATE` urut FK, guard nama DB wajib berawalan `bm2_`.

Gate: `./task check` ≤ 60 s · `./task verify <module>` ≤ 5 min · `./task ci` ≤ 20 min.

---

## 10. Migrasi & cutover (ADR-022, O-10)

Model: **cutover instan, dijalankan manual** (O-10, O-39). Satu kali eksekusi
`cutover.sh` saat operator siap = v2 live. Tidak ada masa berdampingan dan tidak
ada cutover otomatis dari push. ETL dijalankan **sekali**, saat v1 berhenti.

1. R0–R3 berjalan lokal; v1 tetap di produksi tanpa perubahan.
2. **Rehearsal** (boleh berkali-kali): dump `bm` → restore ke `bm_staging` →
   ETL ke `bm2_rehearsal` → migrasi, seed, bootstrap, verifikasi, smoke. Tidak
   menyentuh `bm` maupun `bm2` produksi.
3. **Pemicu = perintah manual.** Tag rilis sudah terbit dan image digest sudah
   ada di GHCR. Operator menjalankan `ops/scripts/cutover.sh --version vX.Y.Z`
   lewat SSH. `deploy-vps.sh` tidak pernah menjalankan cutover dan tidak membaca
   berkas penanda apa pun.
   Guard `cutover_state`: bila `completed_at` sudah terisi, script berhenti dengan
   "already cut over" tanpa menyentuh layanan. Baris parsial **tidak** memblokir,
   supaya `--from <step>` bisa melanjutkan.
4. **Urutan cutover** (satu eksekusi, dengan `trap ERR` + berkas `cutover.step`):
   a. `flock` yang sama dengan deploy; `:v1-final` dibuat dari image v1 yang hidup
      **hanya bila belum ada**, lalu digest-nya diperiksa. Baru setelah tag
      terverifikasi, layanan v1 `systemctl --user stop` **dan `disable`** (supaya
      reboot tidak menghidupkannya). Urutan ini wajib: bila pembuatan tag gagal
      setelah v1 dimatikan, tidak ada jalur pulang. Resume setelah v2 hidup tidak
      boleh menandai v2 sebagai `:v1-final`;
   b. Caddy masuk mode maintenance: semua metode non-GET ke `/api/*` dijawab
      `503` + `Retry-After`, halaman maintenance untuk GET;
   c. layanan v1 dipastikan mati (ticker ingest dan janitor tidak menulis apa pun);
   d. `pg_dump` `bm` → restore ke `bm_staging` (bukan restore langsung ke `bm2`),
      checksum dump dicatat;
   e. `bm2` disiapkan: `bm2_owner` (DDL), `bm2_app` (aplikasi), migrasi, seed L1,
      bootstrap `platform_owner` (`tools/ownerseed --sub`);
   f. ETL **satu transaksi** dari `bm_staging`, lalu verifikasi terhadap staging;
   g. `cutover_state` (satu baris) diisi (`snapshot_sha256`, `snapshot_taken_at`,
      `etl_completed_at`, `rows_imported` per tabel), env ditukar ke `bm2`, snippet
      Caddy v2 diaktifkan (`caddy validate` lalu reload), layanan start;
   h. `/readyz` hijau hanya bila skema cocok **dan** `snapshot_sha256` sama dengan
      `CUTOVER_SNAPSHOT_SHA256` di env; smoke lulus; maintenance dilepas;
   i. `cutover.step` ditulis sebelum dan sesudah setiap langkah. Bila langkah
      mana pun gagal, berkas itu menunjuk langkah terakhir dan script berhenti
      dengan exit ≠ 0; tidak ada resume otomatis.
5. Jika script mati di tengah: `cutover.step` menunjukkan langkah terakhir;
   operator menjalankan `rollback.sh` (kembali ke `:v1-final`, env `bm`, Caddy v1,
   `systemctl --user enable` v1) atau `cutover.sh --from <step>`. Tidak ada
   keadaan setengah jalan tanpa catatan. **Rehearsal kedua wajib dijalankan di VPS
   sungguhan D-3**, termasuk latihan rollback ber-stopwatch, karena Quadlet dan
   Caddy tidak pernah dieksekusi di mesin dev (tidak ada Podman).
6. Poin **dihitung ulang** dari event, bukan disalin.
7. Seluruh data v1 dipetakan ke **satu komunitas default**. **ETL tidak membuat
   membership**; komunitas default read-only sampai `platform_owner` mengangkat
   satu `admin`.
8. Tautan `/s/{code}` lama **tidak dipertahankan**; kode baru diterbitkan per sesi.
9. **Rollback** = `rollback.sh`: image `:v1-final`, env `bm`, snippet Caddy v1,
   unit v1 di-`enable` kembali. `bm` utuh; data `bm2` setelah cutover dibuang;
   `cutover_state` dihapus (barisnya diarsipkan ke audit) sehingga cutover ulang
   tidak diblokir guard; semua sesi v2 tidak berlaku (pengguna login ulang); bundle FE v2 di cache browser harus di-reload paksa
   karena `no-store` hanya berlaku untuk dokumen baru. Runbook menyatakan ini
   eksplisit, termasuk bahwa `410 CLIENT_OUTDATED` tidak ada di v1 sehingga tab
   lama akan gagal dengan error jaringan, bukan pesan yang ramah. `:v1-final`
   dipertahankan **30 hari**, lalu dihapus bersama T-082 setelah tarball image diarsipkan.
10. Tab FE lama menerima `410 CLIENT_OUTDATED` dengan banner reload.
11. **`bm` disimpan permanen sebagai arsip read-only** (O-41). Tidak ada DDL dan
    tidak ada tulisan setelah v1 berhenti. `ops/db/roles.sql` menjalankan
    `REVOKE ALL ON DATABASE bm FROM bm2_app, bm2_etl` dan `REVOKE CONNECT` dari
    `PUBLIC`, sehingga hanya role arsip/admin yang bisa membacanya; asersi
    `has_database_privilege('bm2_app','bm','CONNECT') = false` masuk T-060.
    Satu dump final `pg_dump -Fc bm` dibuat **di luar rotasi 7 hari** dan
    disimpan bersama arsip; dump harian `bm` berhenti setelah 30 hari, sedangkan
    `bm2` tetap harian (O-23).

---

## 11. Risiko teknis

| # | Risiko | Mitigasi | Pemicu pembalikan |
|---|--------|----------|-------------------|
| T1 | Mummy + memory manager tidak stabil | `atomicArc`, RSS gauge, soak 1 juta request | RSS naik monoton |
| T2 | Binder SQL bocor | binder wajib + round-trip test + lint melarang `dbQuote` di store | ada query tanpa binder |
| T3 | OIDC tanpa verifikasi tanda tangan | spike OpenSSL EVP (§7.2); soname eksplisit + boot-check `EVP_DigestVerifyUpdate` | EVP tidak tersedia / `OpenSSL_version` bukan 3.x |
| T4 | Cold compile Nim mendekati 15 menit | nimcache + `deps.lock` + job terpisah | CI > 12 menit |
| T5 | Parity membekukan bug | divergensi wajib | ada kasus "sama dengan v1" pada IDOR |
| T6 | Waktu tidak deterministik | fake clock wajib | fixture kedaluwarsa |
| T7 | Redesign skema kehilangan data | ETL dari dump beku + rekonsiliasi; `bm` utuh | selisih rekonsiliasi > 0 |
| T8 | Backup hilang bersama VPS | diterima (O-23): dump di disk yang sama; restore diuji | disk/VPS hilang |
| T9 | Cutover satu arah tanpa masa berdampingan | `:v1-final` 30 hari + tarball arsip + `rollback.sh` + rehearsal | rollback gagal atau melewati 30 hari |
| T10 | Kunci `SHARE_CODE_KEY` hilang | kunci disimpan di env VPS + salinan aman; `key_id` memungkinkan rotasi | dekripsi gagal saat menampilkan tautan |
| T11 | Cutover terulang / `:v1-final` tertimpa saat resume | guard `cutover_state.completed_at` + "buat hanya bila belum ada" (§8) | `cutover.sh` dijalankan lagi setelah v2 hidup |
| T12 | Kegagalan ETL tidak terdeteksi | probe eksternal + `rows_imported` per tabel + `majadu-alert.service` | `/readyz` 200 tetapi jumlah baris ≠ staging |
| T13 | Review owner menjadi bottleneck, bukan coding | WIP ≤ 3 agen aktif, ≤ 6 task berjalan, budget review 15 menit/task; task > 1 hari dipecah | antrean review > 5 task atau review < 15 menit/task |
| T14 | ETL sekali jalan tidak teruji pada dump produksi | rehearsal dengan dump sintetis + `import_row_map` sebagai jalur re-run + buffer 1–2 hari | selisih rekonsiliasi ≠ 0 di rehearsal |
| T15 | Serah-terima riwayat lewat unlink → klaim akun lain | persetujuan admin + riwayat `released` di antrean + audit dua peristiwa (O-38) | klaim disetujui tanpa melihat riwayat pelepasan |

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
| ADR-016 | Identitas publik = `id` UUIDv7, satu kolom, tanpa identitas publik kedua | diterima (memo 03 vs 04) |
| ADR-017 | `view_code` unik global agar `/s/{code}` bisa diresolusi tanpa komunitas | diterima (§4 butir 8) |
| ADR-018 | Akun dinonaktifkan + dianonimkan; riwayat rating dipertahankan (`ON DELETE RESTRICT` tetap) | diterima (AUTH-10) |
| ADR-019 | FE dan API satu origin | **digantikan ADR-021** (O-22 berubah: FE tetap di Vercel) |
| ADR-020 | SemVer dari Conventional Commits, versi tunggal di `VERSION`, tag annotated, GitHub Release dari tag | diterima (O-24) |
| ADR-021 | FE tetap di `majadu.vercel.app`: HTTP lewat rewrite proxy same-origin + WebSocket auth tiket sekali pakai | diterima (O-22) |
| ADR-022 | Cutover instan: ETL sekali saat v1 dibekukan; tanpa masa berdampingan | diterima (O-10), eksekusi diubah ADR-031 |
| ADR-023 | Satu peran global (`platform_owner`) + tiga peran komunitas (`admin`/`host`/`member`); tidak ada `owner` per komunitas | diterima (O-26) |
| ADR-024 | Image dibangun sekali di CI pada tag, dideploy berdasarkan digest; build lokal hanya untuk dev/rollback | diterima (O-28) |
| ADR-025 | Kode share disimpan sebagai hash + salinan terenkripsi AES-256-GCM agar bisa ditampilkan ulang dengan audit | diterima (O-27) |
| ADR-026 | Tag `:v1-final` dipertahankan 30 hari di luar rotasi `:local`/`:prev`, lalu diarsipkan sebagai tarball sebelum dihapus | diterima (O-29) |
| ADR-027 | Papan peringkat tidak punya pintu publik tanpa kode: `/c/{slug}/rankings` khusus anggota, `/s/{code}/rankings` untuk penonton | diterima (O-32) |
| ADR-028 | Semua klaim pemain wajib persetujuan `admin`; merge hanya `admin` dengan `merge_log` + audit | diterima (O-33) |
| ADR-029 | Tanpa step-up auth; kontrol pengganti = daftar sesi + revoke-all + audit aksi sensitif | diterima (O-37) |
| ADR-030 | Pelepasan klaim = transisi `approved → released` (bukan hapus baris); klaim ulang oleh akun mana pun tetap lewat persetujuan admin, tanpa cooldown | diterima (O-38) |
| ADR-031 | Cutover pertama dijalankan manual via `cutover.sh`; deploy tidak pernah memicu cutover | diterima (O-39), memodifikasi eksekusi ADR-022 |
