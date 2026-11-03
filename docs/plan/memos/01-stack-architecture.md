# Memo 01 — Stack & Arsitektur (Go → Nim)

> **Tanggal:** 3 Nov 2026 · **Panel:** senior Nim engineer + arsitektur · **Target:** backend
> Nim untuk `badminton-match`, v1 (Go) tetap jalan selama transisi.
> **Basis fakta:** pembacaan `docs/audits/2026-11-03/{00,02,06}`, `~/Projects/majadu` (v2 live),
> `~/Projects/cbs` (KRAN), `~/Projects/{qouver,skyward}`, dump skema `.local/schema-bm-2026-11-03.sql`
> (baca struktur saja), dan kode `db_connector` di `~/.nimble/pkgs2`.
> **Aturan:** tanpa secret, IP, atau isi data. Setiap klaim repo lain dirujuk `path:line`.
> **Batasan mode:** memo ini ditulis di `.opencode/plan/memos/` karena sesi berjalan di Plan mode;
> isinya identik dengan yang seharusnya menjadi `docs/plan/memos/01-stack-architecture.md`.

---

## 0. Tiga koreksi terhadap asumsi brief — baca dulu

**(a) `db_connector` tidak memakai parameter terikat.** `db_postgres.dbQuote` hanya menggandakan
tanda kutip tunggal dan memetakan `\0` → `\0` literal (`db_connector/db_postgres.nim:118-126`), lalu
string itu diinterpolasi ke SQL dan dikirim lewat `pqexecParams(..., 0, nil, nil, ...)` — **nol**
parameter (`:134-135`). Jadi setiap query menjadi *escaped concatenation*, bukan bind. Dua repo live
memakai pola ini dan tidak apa-apa sejauh ini, tetapi v1 Go memakai pgx dengan parameter asli, dan
"SQL 100% parameterized" adalah salah satu hal yang audit sebut **sudah benar**
(`00-index.md:138`). Rewrite yang diam-diam kehilangan properti ini adalah regresi tanpa alarm.
→ Keputusan di §2: satu modul binder tipis, wajib, bukan opsional.

**(b) Static linking tidak berlaku di stack ini.** `libpq` dibuka **saat runtime** lewat dynlib
(`cbs/apps/api/Dockerfile:62-63`), dan `std/re` membuka `libpcre` dynlib (`.github/workflows/ci.yml`
cbs, langkah "Runtime libs"). Biner tetap dinamis. Yang bisa dipin adalah **digest base image** +
sha256 tarball Nim (`Dockerfile:20-31`). Jangan janjikan "static binary" ke owner.

**(c) `./task` bukan over-engineering di sini.** Audit v1 menolak migrasi Makefile → `./task`
(`06-architecture.md:450`) — itu benar **untuk Go**, karena `go build` tidak butuh flag. Nim tidak
begitu: `-p:` path, `--mm:`, `--threads:on`, `-d:ssl`, dan urutan `-d:release` adalah bagian dari
definisi biner, dan `nim c` dari direktori mana pun akan gagal tanpa itu. `cbs/task:42,53` dan
`cbs/DECISIONS.md:12` (D-001) menetapkan `./task` sebagai satu-satunya sumber flag. Kita ikut, dengan
alasan yang berbeda dari cbs: bukan disiplin, tapi **kebutuhan**.

---

## 1. Keputusan stack

| Lapisan | Opsi yang dipertimbangkan | Verdict | Alasan (bukti) |
|---|---|---|---|
| Bahasa | Nim 2.4.x | **Nim `>= 2.4.0 & < 2.5.0`** | Dipin sama di `majadu.nimble:5` dan `kran.nimble:18`; toolchain yang diuji = yang di-deploy (`cbs/Dockerfile:23-31`) |
| HTTP | Mummy / Prologue / stdlib asyncnet | **Mummy 0.4.8** | Spike cbs: Mummy 54.341 rps vs Prologue 46.094 vs hand-rolled 18.824 (`cbs/DECISIONS.md:251-253`). Handler boleh **blocking** — wajib, karena driver DB kita sinkron |
| Realtime | SSE / WebSocket / polling | **WebSocket, frame notifikasi** | Mummy **tidak punya** jalur tulis streaming; `respond` selalu `Content-Length` (`majadu/docs/OPEN-QUESTIONS.md:157-166`). Majadu sudah pindah SSE→WS notifikasi dan terbukti e2e (`majadu/docs/DECISIONS.md:1303`, D-050) |
| DB driver | db_connector / norm / ndb / bikin sendiri | **db_connector** + binder sendiri | Satu-satunya yang dipakai dua service live. Sinkron, cocok dengan Mummy worker thread (`majadu/shared/platform-lib/db/pool.nim:1-8`) |
| Pool | bawaan / punya sendiri | **Pool sendiri** (`pool.nim`) | 4.4K, punya `PoolError` → 503, rollback koneksi yang dikembalikan di tengah transaksi (`pool.nim:87-119`) — kasus yang mahal kalau salah |
| Migrasi | Flyway/`dbmate` / runner sendiri | **`tools/dbtools` sendiri** | Ledger + checksum drift + idempotent, sudah live (`majadu/tools/dbtools/lib.nim:1-25`). Detail skema ada di memo 03 |
| Config | registry DB (majadu) / env saja | **env untuk rahasia+operasional, DB untuk parameter bisnis** | Parameter rating sudah ada di tabel `bm.rating_config`; registry + revision polling majadu (`majadu/apps/api/src/main.nim:174-190`) tidak membayar dirinya untuk satu klub |
| Logging | `std/logging` / chronicles / punya sendiri | **Logger tipis sendiri** (adopsi `majadu/shared/platform-lib/log.nim`) | 3.1K, terstruktur, `traceId` per request, tanpa dependensi |
| Metrics | Prometheus client / punya sendiri | **Registry sendiri + listener terpisah** | 2.6K, counters+gauges (`majadu/shared/platform-lib/telemetry/metrics.nim:1-15`); listener terpisah supaya `/metrics` tidak pernah publik (`majadu/apps/api/src/server.nim:163-176`) |
| Testing | `unittest` / `testament` / `balls` | **`std/unittest` + satu biner per modul** | Pola `t*.nim` (unit) + `it*.nim` (integrasi) di `cbs/task:88-93`; integrasi **gagal keras** tanpa DB, bukan skip (`majadu/apps/api/tests/itdb.nim:1-6`) |
| Crypto | nimcrypto / openssl wrapper / libsodium | **nimcrypto 0.7.3** | Cukup untuk HMAC/SHA-256/PBKDF2/`sysrand` (`majadu/shared/platform-lib/crypto/keys.nim:9-60`). **Tidak ada RSA** (lihat §6 R2) |
| Auth | magic link / admin token / **Google OIDC** | **Google OIDC, code flow + PKCE, server-side exchange** | Keputusan owner. Tidak ada kode OIDC di keempat repo rujukan (grep `jwt|oidc|jwks` → kosong) — ini komponen baru, bukan salinan |
| ORM | — | **Tidak ada** | SQL tetap di `infrastructure/`; tidak ada ORM di dua repo rujukan, dan v1 Go juga menolaknya |

### Yang **tidak** diadopsi, dan kenapa

| Dari | Jangan ambil | Alasan |
|---|---|---|
| majadu | **`--mm:orc`** | cbs mengalami `SIGSEGV` nyata di allocator Mummy+ORC, 3 Nov 2026, 1,16 juta request (`cbs/DECISIONS.md:5242-5253`); ORC tidak thread-safe untuk siklus yang berpindah thread. cbs pindah ke `--mm:atomicArc`. Ambil `atomicArc` |
| majadu | **Registry config + revision polling + snapshot lock** | `main.nim:174-190` + thread polling tiap 5 detik. Untuk satu komunitas, ini tiga mekanisme untuk mengganti angka yang bisa dibaca sekali per request |
| majadu | **Multi-community (`community_id` di hampir semua tabel)** | v1 tidak punya konsep komunitas; 27 tabel semuanya datar di schema `bm` |
| majadu | **Mailer/transport + magic-link** | Owner memilih OIDC. Jangan bawa `mail/transport.nim` (12,8K message + 6,3K transport) |
| cbs | `paramgen`, `lint-nomagic`, `traceability`, gate i18n | Kebutuhan perbankan (parameter DB + register regulasi). Untuk 48 rute, biayanya > nilainya |
| cbs | Migrasi dua tahap `contract`/`--down` | Benar untuk skema perbankan berumur panjang. Untuk rewrite yang skemanya masih dibentuk, cukup expand + ledger (memo 03) |
| keduanya | YAML/`yaml == 2.2.1` | Tidak ada kebutuhan baca YAML di runtime; OpenAPI dibaca tooling, bukan server |

---

## 2. Dependensi, dipin persis

`badminton.nimble` (nama paket = nama repo, ikut `cbs/DECISIONS.md:779` D-038):

```nim
requires "nim >= 2.4.0 & < 2.5.0"
requires "mummy == 0.4.8"        # HTTP + WebSocket; satu-satunya server yang diuji
requires "nimcrypto == 0.7.3"    # SHA-256, HMAC, PBKDF2, sysrand
requires "https://github.com/nim-lang/db_connector#29450a2063970712422e1ab857695c12d80112a6"
# Mummy's own requirements float on `>=`; pin the transitive set explicitly so a
# fresh `nimble install` produces the same tree. Same reason as majadu.nimble:8-19.
requires "zippy == 0.10.20"
requires "webby == 0.2.1"
requires "crunchy == 0.1.11"
requires "nimsimd == 1.3.2"
```

| Dependensi | Kenapa ada | Catatan |
|---|---|---|
| `mummy 0.4.8` | Server HTTP + WS | Batas versi: naikkan hanya lewat daftar periksa `cbs/DECISIONS.md:779-800` (D-037) — `WebSocket.send`/`close` dari thread lain adalah **detail internal**, bukan kontrak |
| `nimcrypto 0.7.3` | Hash/MAC/random | Tanpa RSA → §6 R2 |
| `db_connector` (commit) | libpq binding | Tanpa tag sama sekali; `== 0.1.0` akan mengikuti default branch (`majadu.nimble:11-13`) |
| `zippy`, `webby`, `crunchy`, `nimsimd` | Transitif Mummy | Dipin eksplisit, bukan dipakai langsung. **Jangan** import di kode kita |

**Tanpa `nimble.lock`.** Berkas lock mematikan path Nimble global saat file itu ada, sehingga `nim c`,
`./task`, dan nimsuggest tidak menemukan satu pun import (`majadu.nimble:15-19`). Pin manual + commit
SHA adalah penggantinya.

**Satu tambahan yang kita tulis sendiri** (bukan dependensi, tapi wajib):
`shared/platform-lib/db/bind.nim` — mengubah `?` menjadi `$1..$n` dan mengirim nilai sebagai array
parameter `pqexecParams`. ~150 baris, tanpa dependensi. Tanpa ini, §0(a) berlaku dan klaim
"parameterized" hilang. Test wajib: `'`, `\`, `\0`, unicode, `NULL` round-trip.

---

## 3. Layout repo

Alasan memilih `modules/` — berbeda dari kesimpulan audit v1 — adalah **8 domain dengan aturan
masing-masing**, bukan 21K LOC Go dalam satu bounded context. `06-architecture.md:121-135` menolak
`modules/` karena saat itu hanya ada satu agregat; dengan rating, turnamen, achievement, dan share
dipisah, batas itu jadi nyata dan harus ditegakkan compiler.

```text
badminton-match/
├── AGENTS.md  DESIGN.md  VERSION  config.nims  badminton.nimble  task
├── apps/
│   ├── api/
│   │   ├── Dockerfile            # konteks build = root repo (lihat cbs/Dockerfile:9-13)
│   │   ├── src/
│   │   │   ├── main.nim          # composition root + --role serve|migrate
│   │   │   ├── server.nim        # perakitan Mummy: router, middleware, metrics listener
│   │   │   ├── routes.nim        # agregator RouteSpec (satu-satunya daftar rute)
│   │   │   ├── context.nim       # AppContext: pool, log, metrics, config
│   │   │   ├── session_routes.nim tournament_routes.nim rating_routes.nim
│   │   │   ├── player_routes.nim achievement_routes.nim share_routes.nim
│   │   │   ├── account_routes.nim platform_routes.nim
│   │   │   └── version_gen.nim   # dihasilkan ./task build dari VERSION
│   │   └── tests/                # hit*.nim (HTTP), it*.nim (DB)
│   └── web/                      # React 19 + Vite + Tailwind 4 (STACK DIBEKUKAN)
├── modules/
│   ├── session/{domain,infrastructure,migrations,tests}
│   ├── player/…
│   ├── rating/{domain,application,infrastructure,migrations,tests}
│   ├── tournament/…
│   ├── achievement/…
│   ├── share/…                   # tanpa tabel sendiri
│   ├── platform/…                # outbox, idempotency, audit
│   └── account/…                 # identitas OIDC, peran host/admin
├── shared/platform-lib/{db,log,telemetry,net,crypto,problem,limit}
├── tools/{dbtools,archcheck,devseed,ownerctl}
├── ops/{scripts,systemd,webhook,env,caddy}
└── docs/{plan,decisions,handbook}
```

### 3.1 Kepemilikan modul

| Modul | Tabel (dari dump, struktur saja) | Aturan domain | **Dilarang** import |
|---|---|---|---|
| `session` | `sessions`, `session_courts`, `session_players`, `scheduled_games`, `scheduled_game_players`, `fix_matches` | skor 0–99, tidak seri, slot/court unik, transisi status, auto-lock, OCC `version` | `rating`, `tournament`, `achievement`, Mummy, `db_connector` (di `domain/`), `httpclient` |
| `player` | `players`, `player_aliases` | nama kanonik, alias merge, tier sticky, `IsPlaceholderName` (satu-satunya sumber aturan — lihat `02-backend.md:193-203`) | `session`, `rating`, `tournament`, driver |
| `rating` | `rating_config`, `rating_events`, `rating_sources`, `rating_deltas`, `rating_players`, `rank_point_levels`, `rank_snapshots` | poin BWF 12 minggu, best-N, clamp, replay/idempotency | `session` (hanya lewat port pembaca), `tournament`, Mummy |
| `tournament` | `tournaments`, `tournament_{groups,matches,pairs,pair_players,teams,team_matches,team_match_games,team_players}` | format classic vs team, bracket, skor per partai | `session`, Mummy |
| `achievement` | `player_achievements` | aturan badge, satu helper tanggal WIB | `rating`, `session` (lewat port) |
| `platform` | `outbox_events`, `idempotency_keys` | outbox transaksional, dedupe ber-hash body | semua modul lain (**arah sebaliknya**), Mummy |
| `account` | — (tabel baru) | OIDC, sesi cookie, peran host/admin | `session`, `tournament`, `rating` |
| `share` | — (proyeksi baca) | hanya baca; redaksi field; capability `share_code` | semua **write** API modul lain, Mummy |

**Aturan import yang ditegakkan `tools/archcheck`:**
1. `domain/` hanya import `std/` + `shared/platform-lib/crypto` + `shared/platform-lib/problem`.
   Nol `db_connector`, nol `mummy`, nol `httpclient`.
2. `infrastructure/` boleh import `domain/` + `shared/platform-lib/db`; **tidak** boleh import
   `apps/`.
3. Antarmodul **hanya lewat `api.nim`** (permukaan eksplisit), bukan `../session/infrastructure/*`.
   Ini yang mencegah `acommodation` bergaya "store memanggil store" seperti `store/rank_points.go`
   di v1.
4. `apps/api/src/*_routes.nim` boleh import `context` + modul `api.nim`; **tidak** boleh import
   `infrastructure/` langsung.

`share_code` dipisah dari identitas: dump menunjukkan `sessions.id uuid` adalah PK dan `share_code`
kolom terpisah (`schema:544-564`). v1 menyatukan keduanya di `SessionMeta.ID` — itulah akar P0-A
(`02-backend.md:53-65`). Di v2 `share_code` **hanya** capability tulis, tidak pernah muncul di
payload baca publik.

---

## 4. Ergonomi build & dev

**`config.nims`** — pakai `thisDir()`, **bukan** `projectDir()`; kalau salah, `nim check
apps/api/src/main.nim` melaporkan setiap import lintas modul "cannot open file" (`majadu/config.nims:1-9`).
Salin bentuk itu, dan tambahkan `-d:ssl` di sini (bukan hanya di `./task`) supaya cek satu berkas
mengompilasi program yang sama dengan build (`majadu/config.nims:18-21`):

```nim
import std/os
let root = thisDir()
for dir in ["shared", "modules", "apps", "tools"]:
  switch("path", root / dir)
switch("define", "ssl")   # OIDC token exchange + JWKS fetch = outbound HTTPS
```

**Perintah harian**

| Tujuan | Perintah |
|---|---|
| Cek satu berkas (detik) | `nim check --path:shared --path:modules --path:apps modules/session/domain/sessions.nim` |
| Tanya kompiler soal simbol (AGENTS.md) | `printf 'def modules/session/infrastructure/session_store.nim:120:14\nquit\n' \| nimsuggest --stdin apps/api/src/main.nim` — argumen adalah **project file** yang memuat posisi, dan path modul lewat `config.nims` |
| Cek instan seluruh repo | `./task check-fast` (nim check paralel, tanpa lint/format) |
| Verifikasi satu modul | `./task verify <module>` |
| Gate penuh | `./task ci` |

**Flag build, satu sumber** (`./task:42,53`):

```sh
NIMFLAGS="--hints:off --warnings:on --path:$ROOT/shared --path:$ROOT/modules \
          --path:$ROOT/apps --path:$ROOT/tools"
TESTFLAGS="$NIMFLAGS --threads:on --mm:atomicArc"
nim c $NIMFLAGS -d:release --mm:atomicArc --threads:on -o:.build/bin/badminton-api \
      apps/api/src/main.nim
```

-`-d:release` + `--mm:atomicArc` + `--threads:on` wajib **identik** di `./task` dan `Dockerfile`
(`cbs/Dockerfile:59`). Gate yang menguji memory manager berbeda dari produksi tidak menguji apa pun
(`cbs/DECISIONS.md:5256-5278`, D-201).

**Incremental:** `nim c` menulis `.build/`; jangan letakkan biner di `bin/` root. `nim check` per
berkas di-shard paralel — cbs memakai 4 job (`cbs/task:121-155`), dan itu yang membuat `check` 90
berkas selesai dalam hitungan detik, bukan menit.

**Build image:** konteks build = **root repo**, bukan `apps/api/` — `COPY shared/ modules/` tidak
terlihat kalau konteksnya subdirektori (`cbs/Dockerfile:9-13`). Base image dipin digest, tarball Nim
dipin sha256.

---

## 5. Agar subagent paralel tidak bertabrakan

Aturan: **kepemilikan berdasarkan direktori, bukan berdasarkan kekhawatiran.** Satu berkas = satu
pemilik selama satu fase.

| Workstream | Pemilik berkas | Tidak boleh menyentuh |
|---|---|---|
| **W1 core** (blocking semua) | `shared/platform-lib/*`, `apps/api/src/{main,server,context,routes}.nim`, `config.nims`, `task`, `badminton.nimble`, `apps/api/Dockerfile` | semua `modules/` |
| **W2 session** | `modules/session/**` + `apps/api/src/session_routes.nim` | `routes.nim`, `shared/` |
| **W3 rating** | `modules/rating/**` + `apps/api/src/rating_routes.nim` | `modules/player/**` (pakai `player/api.nim`) |
| **W4 tournament** | `modules/tournament/**` + `apps/api/src/tournament_routes.nim` | `modules/session/**` |
| **W5 identity** | `modules/account/**`, `modules/platform/**`, `apps/api/src/{account,platform}_routes.nim` | modul bisnis |
| **W6 data** | `tools/dbtools/**`, `modules/*/migrations/**` | kode aplikasi |
| **W7 web** | `apps/web/**` | seluruh tree Nim |
| **W8 ops/CI** | `ops/**`, `.github/workflows/**` | `task` (milik W1) |

**Titik pertikaian nyata, dan cara memecahnya:**
1. `routes.nim` adalah satu berkas yang disentuh semua orang. Pecah: setiap workstream mengekspor
   `xxxRoutes(): seq[RouteSpec]` di berkasnya sendiri; `routes.nim` hanya `concat` (pola
   `majadu/apps/api/src/routes.nim:63,75`). Setelah kerangka ada, hanya W1 menyentuh agregator.
2. `shared/platform-lib/problem.nim` (amplop error) dipakai semua. **Bekukan di hari pertama** W1,
   sebelum W2–W5 mulai.
3. Migrasi: nomor urut global bertabrakan kalau dua workstream menambah bersamaan. Pakai
   `<NNNN>_<modul>_<slug>.sql` dengan rentang yang dipesan per modul (W6 mengalokasikan), pola
   `majadu/tools/dbtools/lib.nim:3-6`.
4. `config.nims` dan `task` disentuh semua orang secara tidak sengaja. W1 memilikinya; workstream
   lain meminta lewat pesan, bukan commit.

**Kontrak sebelum kode:** W1 menghasilkan tabel `RouteSpec` (path, method, operationId, budget) untuk
48 rute lebih dulu. Tanpa itu, W2–W5 akan menebak nama path dan bertabrakan di `openapi.yaml`.

---

## 6. Risiko & mitigasi

### R1 — Mummy + memory manager (tertinggi)
Bukti: `SIGSEGV` di allocator pada 1,16 juta request dengan ORC (`cbs/DECISIONS.md:5244-5254`).
YRC — pilihan yang benar secara teori — **ditolak Mummy saat kompilasi** (`:5271-5272`).
Mitigasi: `--mm:atomicArc` di semua biner termasuk test; soak test 20k request di CI nightly; ukur
RSS dan catat angkanya (cbs mengukur 17,9 → 23,9 MB lalu datar, `:5273-5276`).
**Balik keputusan bila:** RSS produksi naik monoton >10% per 24 jam, atau Mummy merilis versi yang
menerima YRC.

### R2 — OIDC tanpa library JWT
`nimcrypto 0.7.3` tidak punya RSA (diperiksa: tidak ada modul `rsa` di paket). Tidak ada satu pun
kode OIDC/JWT di empat repo rujukan.
Mitigasi: **code flow + PKCE**, tukar `code` di server ke token endpoint Google lewat
`std/httpclient` (`-d:ssl`; pola outbound HTTPS yang sama dengan `majadu/shared/platform-lib/mail/transport.nim:8`).
Token diterima **langsung dari Google** lewat TLS, jadi verifikasi tanda tangan `id_token` boleh
dilewati menurut dokumentasi Google; yang **wajib** divalidasi: `iss`, `aud` (client id kita),
`exp`, `nonce` yang kita terbitkan sendiri (cookie HttpOnly), `email_verified`. Asumsi ini harus
ditulis di `docs/decisions` sebagai ADR, bukan komentar kode.
**Balik keputusan bila:** butuh verifikasi offline (mis. token dari FE), atau audit menuntut
validasi tanda tangan. Jalur: modul `rs256.nim` isolasi di atas OpenSSL EVP + test vector, atau
paket JWT pihak ketiga — **jangan** tulis parser JWT sendiri.

### R3 — Mummy tidak bisa streaming (SSE)
Fakta terukur: `respond` selalu `Content-Length`, tidak ada penulis chunked
(`majadu/docs/OPEN-QUESTIONS.md:157-166`).
Mitigasi: WS frame notifikasi (`session.changed`), klien refetch — bukan snapshot penuh, supaya board
dan API tidak bisa berbeda (`majadu/docs/DECISIONS.md:1303`). Batas soket per sesi + lifetime, seperti
`majadu/apps/api/src/live.nim` (OWASP-02 di sana).
**Balik keputusan bila:** browser di venue memblokir WS → polling 3 detik (opsi 4 di Q-7), bukan fork
Mummy.

### R4 — Kehilangan parameterisasi SQL (§0a)
Mitigasi: `bind.nim` wajib + test round-trip `'`, `\`, `\0`, unicode, `NULL`. Gate: grep yang gagal
bila ada `sql"...?"` yang tidak lewat binder.
**Balik keputusan bila:** binder terbukti memperlambat jalur panas >5% — saat itu kembali ke
`db_connector` dan **catat** bahwa klaim "100% parameterized" tidak lagi berlaku.

### R5 — Bootstrap migrasi (luka v1 yang sebenarnya)
v1 tidak punya `000001`–`000012` di repo, dijalankan manual, dan bootstrap dari repo gagal
(`00-index.md:86-88`). Rewrite yang mengulang pola itu akan mengulang insidennya.
Mitigasi: migrasi masuk repo sejak commit pertama, ledger + checksum, `./task dbtools migrate`
dijalankan di CI terhadap Postgres service (memo 03). Import data v1 = alat sekali jalan
(`tools/importer`), **bukan** migrasi.

### R6 — Cakupan: 27 tabel + 48 rute dari nol
Mitigasi: kontrak rute dibekukan W1 sebelum W2–W5 mulai; parity harness (memo 06) jadi oracle, bukan
"feeling". Yang **tidak** dikerjakan di fase 1: registry config, multi-tenant, job scheduler,
contract migration.

### R7 — `atomicArc` tidak punya cycle collector
Konsekuensi diterima dan diukur, bukan diasumsikan (`cbs/DECISIONS.md:5273-5276`). Mitigasi: gauge
`process_resident_memory_bytes` + alarm.

### R8 — Regresi capability `share_code`
v1 membocorkan kunci tulis lewat `GET /sessions` (`02-backend.md:53-65`). Mitigasi: `share_code`
hanya di `modules/share`, satu pemilik; test yang gagal bila `share_code` muncul di payload baca
publik mana pun (pola allowlist `majadu/apps/api/tests/tapi.nim`).

---

## 7. Yang membuat saya membalik keputusan ini

| Keputusan | Trigger balik | Arah |
|---|---|---|
| Nim | W1 tidak mencapai 48 rute dalam 3 minggu karena masalah bahasa, bukan domain | Tetap Go, perbaiki P0 di v1 (opsi paling murah yang jujur) |
| Mummy | Butuh HTTP/2, streaming, atau `WS` yang stabil lintas 2 upgrade | Prologue (46k rps, `cbs/DECISIONS.md:251-253`) — tapi kehilangan WS internal |
| `atomicArc` | RSS naik monoton, atau Mummy menerima YRC | YRC; atau `--mm:orc` + `--threads:off` (belum diverifikasi untuk Mummy) |
| WS | Venue memblokir WS, atau >200 penonton per sesi | Polling 3 dtk |
| OIDC claims-only | Butuh verifikasi offline / audit menuntut | RS256 di atas OpenSSL |
| `modules/` | Ternyata hanya 2–3 domain yang benar-benar berbeda aturan | Runtuhkan ke `internal/`; jangan pertahankan struktur demi bentuk |

---

## 8. Ringkasan satu paragraf

Nim 2.4 · Mummy 0.4.8 (HTTP + WS notifikasi) · `db_connector` + `bind.nim` · `tools/dbtools` ·
`--mm:atomicArc --threads:on -d:ssl` · `modules/` 8 domain dengan `api.nim` sebagai satu-satunya
permukaan antarmodul · satu `./task` sebagai sumber flag build · OIDC code-flow sebagai satu-satunya
komponen yang benar-benar baru. Yang paling berbahaya bukan Nim, melainkan tiga hal yang tidak
terlihat sampai produksi: memory manager Mummy (**R1**), klaim parameterisasi yang diam-diam hilang
(**R4**), dan OIDC tanpa library JWT (**R2**).
