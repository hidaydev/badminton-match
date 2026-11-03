# CROSS-CHECK — dokumentasi perencanaan

Tanggal: 2026-11-03
Metode: dua putaran terpisah. Putaran 1 menguji **klaim vs sumber** (kode, dump skema,
library). Putaran 2 menguji **dokumen vs dokumen** (angka, istilah, dependency, traceability).

Aturan yang dipakai: klaim tanpa sumber tidak masuk dokumen; klaim yang bertentangan
tidak dirata-ratakan, tapi dipilih satu dan alasannya ditulis.

---

## Putaran 1 — klaim vs sumber

| # | Klaim | Sumber yang diuji | Hasil |
|---|-------|-------------------|-------|
| 1 | 48 route di v1 | `main.go`, dihitung ulang otomatis | **benar** (48) |
| 2 | Skema `bm` = **27** tabel, 26 index, 4 fungsi | `pg_dump --schema-only` | **benar** (hitungan awal 26 salah) |
| 3 | `GET /sessions` membocorkan `share_code` sebagai `id` | `session_admin.go:169-176,187` + `session.go:119-141` | **benar** |
| 4 | `PUT/PATCH/games/absent/swap` tanpa guard | `main.go:199-208` | **benar** |
| 5 | `POST /sessions` & `POST /tournaments` anonim | `main.go:196,231` | **benar** |
| 6 | `DELETE /sessions/{id}` & `lock` sebenarnya admin | `main.go:201-202` | **benar** (audit 05/01 sempat menyebut anonim; README sudah dikoreksi) |
| 7 | `rating_deltas` tanpa UNIQUE `(event_id, player_id)` | dump, `rating_deltas_pkey` | **salah** — PK sudah ada |
| 8 | Index urut 4 kolom tidak ada | dump, `rating_events_order_uniq` | **salah** — sudah ada |
| 9 | `/ratings/rebuild-all` hilang dari route | `main.go:249` | **salah** — route ada, hanya openapi yang kurang |
| 10 | `Save()` mereset `scheduled_games.version` | `session_write.go:304-340` (DELETE+INSERT) | **benar** |
| 11 | `DeletePlayer` menghapus event semua peserta | `rating_admin.go:119-122` | **benar** |
| 12 | Achievement `tournament` masih ditulis | `store/achievement.go:577` | **benar** (memo/data-model awal salah) |
| 13 | Sparkline masih ada di UI | `grep -ri sparkline apps/web/src` = 0 | **salah** — sudah dihapus dari dokumen |
| 14 | `db_connector` meng-escape, bukan bind | `db_postgres.nim:118` (`dbQuote`) + `db_common` | **benar** |
| 15 | Mummy tidak mendukung SSE | `mummy-0.4.8` tanpa `text/event-stream` | **benar** |
| 16 | nimcrypto tanpa RSA | isi paket nimcrypto 0.7.3 | **benar** |
| 17 | `std/openssl` menyediakan `EVP_DigestVerify*` | `lib/wrappers/openssl.nim` | **salah** — hanya `EVP_DigestSign*`; dibutuhkan binding lokal |
| 18 | IP server bocor di repo | `ops/caddy/Caddyfile.api.qouver.com:3` | **salah** — `198.51.100.10` = RFC 5737 |
| 19 | `1.7 .local` dump tidak masuk git | `git check-ignore` | **benar** (ditambahkan) |

**Konsekuensi yang sudah diterapkan**

- TECH-SPEC §1 memuat tabel koreksi; empat temuan audit diturunkan statusnya.
- TECH-SPEC §7.2 & ADR-009 diubah dari "stdlib sudah punya" menjadi "butuh modul
  binding ±80–120 baris + spike".
- `data-model.md` dan `product-overview.md` di repo sudah dikoreksi lebih dulu
  (commit `08e93a8`) untuk achievement kind dan sparkline.
- Memo security memakai nama tabel `bm.player_ratings`; nama benar `bm.rating_players`
  (typo, tidak memengaruhi desain).

---

## Putaran 2 — dokumen vs dokumen

| # | Yang diuji | Hasil | Tindakan |
|---|------------|-------|----------|
| 1 | Aritmetika permukaan API saat itu: 48 − 7 − 2 + 9 | 48 | diganti tabel per kelompok di TECH-SPEC §5 (kini 62) |
| 2 | Task ID yang dirujuk di `Depends` benar-benar ada | 48 task (saat putaran 1), 0 dangling | — |
| 3 | Task tanpa dependensi | hanya T-001 | disengaja |
| 4 | Setiap requirement PRD punya task | awalnya **1 dari 38** | ditambah §10 matriks traceability |
| 5 | Penamaan tautan: `share_links` (memo 03) vs `session.links` (memo 02) | **konflik** | dipilih `session.links` tanpa `kind`, dicatat di TECH-SPEC §4 |
| 6 | Verifikasi ID token: memo 01 (klaim saja) vs memo 02 (RS256) | **konflik** | diselesaikan di TECH-SPEC §7.2, ADR-009 tetap terbuka |
| 7 | Rute baru vs lama: `/rankings` diklaim baru? | **sudah ada di v1** (`main.go:255`) | tidak dimasukkan sebagai rute baru |
| 8 | Nomor migrasi di dokumen lama (`000013–000016`) | sudah dikoreksi ke `000023` di commit `08e93a8` | — |
| 9 | Istilah `publicId` vs `public_id` | keputusan ADR-016: kolom `id` UUIDv7, JSON `id`; tidak ada `public_id` | menggantikan usulan memo 03/04 |
| 10 | Gate per rilis R0–R4 ada di PRD dan BACKLOG | cocok | — |

---

## Putaran 2b — review peran (scrum master)

Lihat `REVIEW-scrum.md`. Temuan review diadopsi/ditolak secara eksplisit di bawah
(isi bagian ini diperbarui setelah review masuk).

| Temuan review | Keputusan |
|---------------|-----------|
| Task keamanan tanpa pemilik (rate limit, CSRF, idempotency, `/auth/*`) | diadopsi → T-075..T-078, AUTH-07..09 |
| T-006 terlalu besar, lingkup tabel salah | diadopsi → dipecah T-006a–e termasuk `auth.*`, `account.*`, `platform.idempotency_keys` |
| T-013 bergantung pada DB yang salah | diadopsi → T-014 (env v1 lokal) |
| `Owns` glob saling menabrak | diadopsi → semua ke file-level |
| FE tanpa edge ke kontrak, tanpa mock API | diadopsi → T-015, T-016 |
| Edge T-044 → T-028 | **ditolak** — papan publik |
| T-011 "hijau di PR" tanpa push | diadopsi (diubah) → `actionlint` + `./task ci` |
| T-060 acceptance sirkular dengan T-063 | diadopsi → drill dipindah |
| Dekomisi Go & keputusan freeze poin belum ada task | diadopsi → T-082, T-083 |

---

## Putaran 3 — keputusan pemilik (2026-11-03)

Enam pertanyaan dijawab. Empat jawaban hanya mengonfirmasi rencana; dua mengubah desain
dan memaksa penyuntingan lintas dokumen:

| Jawaban | Yang harus diubah | Berkas yang disentuh |
|---|---|---|
| Semua penulis login Google; tidak ada host tanpa login | `edit_code` dihapus dari model kapabilitas, skema `session.links`, kontrak, UX, dan acceptance task | BRD, PRD, TECH-SPEC §4/§7.3, BACKLOG T-024/T-030/T-070 |
| P0 diterima apa adanya, tanpa kontrol kompensasi | §7.5 berubah dari "usulan kontrol" menjadi "risiko diterima"; ADR-011 dibuat | BRD R1, TECH-SPEC §7.5/§12, BACKLOG T-083 |
| RS256 via binding OpenSSL | ADR-009 dari "terbuka" menjadi "diterima"; verifier dipisah jadi task sendiri | TECH-SPEC §7.2/§12, BACKLOG T-084, T-021 |
| `member` di R2 | tabel rilis + task klaim profil | PRD R2, BACKLOG T-048 |
| Rilis kosong, impor setelah stabil | urutan cutover vs impor | TECH-SPEC §10 |
| `view_code` read-only | acceptance keamanan | BACKLOG T-070 |

Konsistensi pasca-perubahan diuji ulang: tidak ada sisa `edit_code`/`X-Edit-Code`
di dokumen, dan seluruh requirement PRD (saat itu 41) tetap terpetakan.

---

## Putaran 4 — perluasan lingkup: multi-komunitas + frontend dibekukan

| Keputusan | Yang berubah | Berkas |
|---|---|---|
| Multi-komunitas masuk repo ini (O-13..O-16) | tujuan bisnis B7, requirement COM-01..10, skema ber-`community_id` + FK komposit, routing `/c/{slug}`, poin per komunitas, peran per komunitas | BRD §2/§4/§7/§9, PRD §3/§4.0/§6, TECH-SPEC §0/§3/§4/§5/§6/§7/§10/§12, BACKLOG T-090..T-095 + T-006a/d + T-025..T-053, traceability |
| Frontend React dibekukan (O-17) | memo 01 salah menulis `web/ # Svelte`; diperbaiki, dan larangan rewrite dicatat eksplisit | BRD C7/O-17, PRD §8, TECH-SPEC §2/§3/§12 |

**Cek konsistensi setelah perluasan:**

| Yang diuji | Hasil |
|---|---|
| Sisa kata "Svelte" di dokumen hidup | hanya di memo 01 sebagai catatan yang sudah dikoreksi |
| "Multi-community" masih disebut di luar lingkup | tidak ada |
| Task ID baru (T-090..T-095) | tidak menggantung, semua `Depends` valid |
| Requirement COM-01..10 | seluruhnya terpetakan ke task |
| Kolom `community_id` di setiap tabel domain | disebut di TECH-SPEC §4 dan acceptance T-006a |
| Tautan `view_code` | tidak ada sisa `edit_code` di dokumen hidup |

---

## Putaran 5 — parameter/DB-driven

Prinsip: **tidak ada angka bisnis di kode** (O-18/O-19). Nilai berlapis:
`platform.config` → `community.settings`; tidak ada lapis ketiga berupa konstanta.

Angka v1 yang wajib pindah, semuanya diverifikasi di kode:

| Nilai | Lokasi | Key |
|---|---|---|
| ticker ingest 30 menit | `main.go:149` | `ingest.ticker_minutes` |
| pagination granular 100 | `handler/granular.go:35` | `api.page_size_default` |
| papan 200 | `handler/ratings.go:193` | `rank.board_limit` |
| band tier 1000–2100+ | `domain/rating_config.go:88-92` | `rating.tier_bands` |
| tepat 16 pair | `domain/tournament.go:61` | `tournament.classic.pair_count` |

Konsekuensi desain yang sudah masuk dokumen: tabel `platform.config` +
`platform.config_version`, registry bertipe, cache dengan invalidasi, tolak-start bila
key wajib hilang, plafon platform untuk override komunitas, dan `archcheck` yang
menggagalkan build pada literal yang menduplikasi key.

**Cek konsistensi:** requirement CFG-01..08 seluruhnya terpetakan (T-096..T-098);
T-094 yang sempat hilang saat penyuntingan sudah dikembalikan; jumlah task naik dari
68 → 71.

---

## Putaran 6 — database `bm2` terpisah

Keputusan O-20: `bm2` adalah **database** baru di instance yang sama, dengan role
`bm2_app` tanpa akses ke `bm`. Alasan: isolasi backup, hak akses, ledger migrasi, dan
restore — sesuatu yang tidak didapat dari schema tambahan.

Yang berubah: BRD §4, TECH-SPEC §4, README ringkasan, BACKLOG T-007 (nama DB dev),
dan catatan status di memo 03. Yang **tidak** berubah: verdict redesign, `bm` nol DDL,
dan rencana impor.

---

## Putaran 7 — audit menyeluruh dokumen perencanaan

Dijalankan setelah seluruh keputusan masuk (O-1..O-20). Ini pemeriksaan **mesin**,
bukan pembacaan manual, supaya angka tidak bisa "kira-kira".

| Pemeriksaan | Metode | Hasil |
|---|---|---|
| Integritas task | parse tabel backlog (saat putaran itu) | **85 task**, 0 duplikat, 0 dependency menggantung |
| Kepemilikan file | kumpulan `Owns`, cari irisan | **0 bentrok** setelah pemisahan per file |
| Traceability | requirement PRD vs referensi backlog (saat putaran itu) | **0 tidak terpetakan**, 0 referensi hantu |
| Angka yang diklaim | grep `41`, `51`, `60`, `68`, `48 → 48`, `8 domain` | 5 klaim basi, semuanya diperbaiki |
| Klaim v1 yang jadi dasar config | cek langsung ke kode | ticker `main.go:149`, pagination `granular.go:35`, papan `ratings.go:193`, band `rating_config.go:88-92`, 16 pair `tournament.go:61` — semua cocok |
| Istilah terlarang | grep `Svelte`, `edit_code`, `multi-tenant di luar` | hanya muncul sebagai larangan/penjelasan, bukan desain |
| Link relatif | 11 berkas di `docs/plan` | **semua resolve** |
| Secret scan | grep IP/token/private key | bersih |

**Perbaikan yang dilakukan selama audit ini:**

1. `README.md` masih menulis "41 requirement" dan "60 task" → 59 dan 71.
2. `CROSS-CHECK` menyebut "41 tetap terpetakan" pada putaran sebelumnya → diberi
   konteks "saat itu".
3. Permukaan API masih "48 → 48" → 59 (49 tanpa komunitas + 10 komunitas).
4. Memo 01 masih "8 domain" → diberi catatan 9 domain.
5. Memo 04 masih "48 → 48" → diberi catatan 59.
6. `testdata/parity/` diklaim dua task → dipecah `v1/` (T-013) dan `v2/` (T-071).
7. `bm2` ambigu antara schema dan database → database terpisah (O-20), memo 03
   diberi catatan status.

---

## Putaran 8 — kelayakan lingkungan

Diuji di mesin ini, bukan diasumsikan:

| Alat | Hasil | Dampak |
|---|---|---|
| Nim | 2.4.0 arm64 | sesuai pin |
| pnpm | 11.25.0 | sesuai `packageManager` |
| PostgreSQL | 18.6 Homebrew, **berjalan** | DB dev bisa langsung dipakai |
| psql | 18.6 | inspeksi & reset |
| Go | 1.27.3 | cukup untuk capture parity v1 |
| **Podman** | **tidak terpasang** | T-007/O-5 diubah: server lokal jadi default, container hanya fallback |

Cluster lokal sudah berisi banyak database uji proyek lain (`*_test`, `*_e2e`).
Karena itu penamaan `bm2_dev` + guard nama wajib, dan reset tidak boleh menyentuh
database di luar prefiks `bm2_`.

---

## Putaran 9 — tiga review independen

Tiga reviewer dengan sudut berbeda membaca seluruh rencana. Ringkasan dan tindakan:

| Review | Temuan utama | Tindakan |
|---|---|---|
| `reviews/executability.md` | `task`/`config.nims` satu pemilik; Dockerfile tanpa pemilik; rantai DB tanpa T-007; T-014 tanpa produsen data; seed config tidak ada; kontrak auth bentrok; T-008 "48" vs 58; context/sha256 tanpa pemilik; 3 tabrakan `Owns`; tabel tanpa migrasi; acceptance tak terverifikasi; T-082 tak bisa bersih; client FE lama | **14/14 diterima** → T-018 dispatcher, T-099 fixture, T-085 stub OIDC, T-101 pensiun client, T-102 ops token, T-103 bootstrap, `Owns` dipecah per file |
| `reviews/consistency.md` | 27 tabel (bukan 26); T-008 48 vs 59; SES-02 403 vs 401; PLY-01 anonim; `session.links` 4 penamaan; `public_id` vs `id`; memo K1–K6 vs O-8; memo 01 "8 domain"; `POST /auth/google`; path WS; ADR-010 tanpa desain; AUTH-06 salah task | **semua diterima**; ADR-015/016/017 ditambahkan, memo diberi catatan status |
| `reviews/adversarial.md` | pool 8 vs `serverThreads` 10× core; NULL→`""` dan `?` di jsonb; nimcache per nama file; FK komposit `MATCH SIMPLE`; share code per komunitas vs `/s/{code}`; bootstrap instance kosong; `libcrypto` dynlib | **semua diterima** → T-004 PQexecParams, T-018 nimcache, TECH-SPEC §4 butir 11, ADR-017, T-103, T-084 cek boot |

Angka yang berubah: task **71 → 80**, permukaan API **59**, tabel v1 **27**.
Requirement menjadi **62** (AUTH-10, OPS-06, OPS-07) dan seluruhnya terpetakan.

---

## Putaran 10 — keputusan interaktif pemilik (2026-11-03)

| Topik | Keputusan | Wujud |
|---|---|---|
| Topologi origin | FE `majadu.qouver.com` + API `api.qouver.com`, satu site | ADR-019, O-22, T-061, T-076 |
| Backup | `pg_dump` harian, retensi 7, snapshot sebelum ETL, restore diuji | O-23, T-060, T-063, T-064 |
| Retensi data | Janitor otomatis | OPS-06, T-105 |
| Google OAuth | Belum ada kredensial; runbook wajib | T-021, `docs/ops/google-oauth.md` |
| Dekomisi Go | Setelah cutover + 30 hari observasi | T-082 |
| Unit test FE | vitest | T-028, T-046, T-054 |
| Cutover | Deploy berpasangan, HTML `no-store`, aset ber-hash | TECH-SPEC §8, T-065 |
| Hapus akun | Nonaktifkan + anonimisasi, riwayat tetap | ADR-018, AUTH-10, T-106 |
| Arah desain | `docs/design-system.md` yang ada | T-028, T-093 |
| Bahasa UI | Inggris saja, kunci i18n disiapkan | O-21, T-028 |
| Observability | 8 metrik inti, tanpa alert | TECH-SPEC §8, T-062 |

Angka: task **80 → 84**, requirement **59 → 67**, operasi **59 → 66** (lihat putaran 13).

---

## Putaran 11 — cutover instan & Vercel (2026-11-03)

| Topik | Keputusan | Konsekuensi yang diterima |
|---|---|---|
| Nasib v1 | Cutover instan, tanpa berdampingan (putaran 15: dijalankan manual `cutover.sh`) | Tidak ada jendela uji paralel; rollback = restart image v1 |
| Data | ETL sekali dari dump beku saat v1 berhenti (menggantikan pra-impor) | Baris yang ditulis v1 antara dump dan start hilang; dicatat di runbook |
| Tautan lama | Kode baru diterbitkan; `/s/{code}` v1 mati | Pengguna harus menerima tautan baru |
| FE | Tetap `majadu.vercel.app`; HTTP lewat proxy same-origin `/api/*`, WS dengan tiket | Satu endpoint baru `ws-ticket`; **diganti putaran 13**: Caddy menulis `X-Client-IP`, aplikasi tidak membaca XFF |
| Rilis pertama | `2.0.0`, tag SSH-signed, lampiran digest image | Tidak ada fase 0.x; aturan bump major/minor/patch langsung berlaku |
| Repo publik | Push hanya setelah v2 live dan v1 mati | Riwayat audit berisi langkah eksploitasi P0, jadi tidak boleh terbit lebih awal |

Perubahan angka: operasi **59 → 60** (`POST …/ws-ticket`), requirement **62 → 63**
(AUTH-11), task tetap **83**. ADR-019 digantikan ADR-021; ADR-022 ditambahkan.

---

## Putaran 12 — empat review independen (keamanan, cutover, konsistensi, produk)

| Area | Temuan yang diterima | Perbaikan |
|---|---|---|
| Keamanan | redirect OAuth didaftarkan di host API padahal cookie flow hidup di host FE → login mustahil atau login CSRF | callback lewat `/api/auth/google/callback`; `return_to` wajib relatif; test open-redirect di T-070 |
| Keamanan | aturan IP di balik dua rantai proxy (Vercel HTTP, WS langsung) tidak terdefinisi | `trusted_proxy_cidrs` + aturan "hop paling kanan yang bukan proxy"; XFF dari peer non-proxy diabaikan |
| Keamanan | tiket WS tanpa penyimpanan, rawan balapan dan bocor di log | tabel `platform.ws_ticket`, konsumsi `DELETE … RETURNING`, redaksi parameter `ticket` |
| Keamanan | pencabutan tidak menutup socket | logout/rotasi/perubahan peran menutup koneksi |
| Cutover | ETL punya dua pemilik (`CUTOVER=1` vs manual) dan dump lama | ETL sekali dari dump beku; **diganti putaran 15/16**: seluruh urutan di `cutover.sh`, tidak ada `CUTOVER=1` |
| Cutover | push cutover memakai script lama ("berlaku deploy berikutnya") | self re-exec |
| Cutover | `flock -n` + `exit 0` membuang deploy; gate hanya `/healthz` | `flock -w 900` + `exit 1`; gate `/readyz` + `cutover_state` |
| Cutover | `:prev` menggusur v1 sebelum 14 hari | tag `:v1-final` (ADR-026) |
| Cutover | Caddy tetap `/majadu/*`, tidak pernah reload | snippet v1/v2 + `switch_site` dengan `caddy validate` |
| Cutover | digest rilis tidak jelas asalnya | image dibangun sekali di CI, deploy by digest (ADR-024) |
| Produk | lock tidak pernah menyetujui sumber poin | lock menstempel `approved_at`; SES-06/07/08 ditulis ulang |
| Produk | komunitas baru/default tidak punya admin | COM-01 wajib email admin pertama; default read-only sampai diangkat |
| Produk | penonton tidak bisa dapat tiket WS | `POST /s/{code}/ws-ticket` anonim, per kode + IP |
| Produk | klaim pemain tanpa aturan | PLY-04 (putaran ini): klaim bebas untuk yang belum diklaim, merge oleh admin — **diganti putaran 14**: semua klaim lewat persetujuan admin |
| Produk | RNK-01 mengklaim monoton | dihapus; window bergeser bisa menurunkan poin |
| Konsistensi | `Owns` direktori bertabrakan, 5 task tanpa agen, sisa model lama | dipersempit, lane dilengkapi, teks diperbarui |
| Desain | `platform_owner` tidak bisa menjadi anggota sehingga tidak bisa klaim profil dan ikut bermain | AUTH-12: boleh join sebagai `member` tanpa undangan (audit); kekuasaan global tetap independen |

Angka **pada putaran itu**: task 83 → 84 (T-108), requirement 63 → 65 (PLY-04,
AUTH-12), operasi 60 → 63 (tampil-ulang share, tiket penonton, join), ADR 22 → 26,
keputusan O-1..O-29. Angka final ada di putaran 14.

Risiko yang **diterima** (bukan lupa): backup tetap di disk VPS; komunitas default
read-only setelah cutover; ETL tidak membuat membership.

---

## Putaran 13 — review delta (keamanan & eksekusi)

| Area | Temuan | Perbaikan |
|---|---|---|
| Peran | `platform_owner` tidak punya route join; T-020 melarang membership | `POST /c/{slug}/join` (operasi 63), AUTH-12, T-091 |
| Anonimisasi | `sub` dihapus tetapi login harus ditolak; klaim pemain menggantung | simpan `sha256(sub)`, NULL-kan `player.user_id` |
| Share | `key_id` tanpa keyring; format ciphertext tanpa nonce/tag/AAD | `SHARE_CODE_KEYS` + kunci aktif wajib, format `versi\|nonce\|ct\|tag`, AAD `community_id\|link_id` |
| WS | pencabutan tidak menghapus tiket; `channel` tidak kanonik | kanal `session:<id>`/`share:<link_id>`, hapus tiket saat revoke |
| IP | aplikasi selalu melihat loopback; CIDR Vercel tak bisa diandalkan | Caddy menulis `X-Client-IP`, aplikasi tidak membaca XFF |
| Log | kode di path `/s/{code}` masuk access log | redaksi di Caddy + logger |
| Klaim | tidak ada unique parsial per komunitas | `UNIQUE(community_id,user_id)` |
| Cutover | `CUTOVER=1` tak bisa lewat webhook; tanpa `trap`; `:v1-final` tak pernah dibuat | penanda `cutover.request` + `trap` + `cutover.step`; **diganti putaran 15**: cutover manual `cutover.sh` |
| Cutover | sumber ETL tiga versi | sumber tunggal `bm_staging` |
| Rilis | deploy bisa jalan sebelum image ada; pull tanpa auth | urutan tag → digest → `main`; `podman login` + token |
| T-108 | `git filter-repo` rusak di mesin ini | acceptance mewajibkan perbaikan alat, `--force`, origin dipasang ulang, `--force-with-lease` |

## Putaran 14 — lima SME (DB, Nim, abuse, SRE, QA)

Lima review independen ditulis di `reviews/round-4-*.md`, masing-masing menyerang
area yang belum diuji: DDL, kelayakan pustaka, jalur penyalahgunaan, kegagalan
operasional, dan test yang tidak bisa gagal. Yang diterima:

| Area | Temuan | Perbaikan |
|---|---|---|
| DB | `0001` memuat FK ke `platform.community`/`user` yang dibuat di `0004` | tabel platform inti pindah ke `0001`; D1 |
| DB | FK komposit mustahil tanpa `UNIQUE(community_id,id)` di parent | D2 + index anak D3 |
| DB | `session.links` tanpa `community_id`; `id` berdefault; `expires_at` wajib | D4–D6, kolom ditambah |
| DB | `UNIQUE(community_id, slug)` menghapus keunikan slug | slug unik global (O-32 tidak berlaku untuk identitas platform) |
| DB | `join_request` unik polos memblokir pengajuan ulang | unik parsial `WHERE status='pending'` + CHECK (D7) |
| DB | `cutover_state` bisa multi-baris; `ws_ticket.channel` teks bebas; `import_row_map` PK global | D8, D9, D10 |
| DB | `player.user_id` unik gagal saat merge; nama mentah duplikat | `canonical_key` + unik parsial (D11) |
| DB | `rating.deltas` RESTRICT dua sisi membuat hapus turnamen gagal | urutan delete eksplisit + uji negatif |
| DB | index papan/sesi/rating hilang atau salah kolom | index berawalan `community_id`, tanpa `now()` |
| DB | ETL menyalin `id` v4 sementara ADR-016 menjanjikan v7 | UUIDv7 baru + peta di `import_row_map` |
| Nim | `dynlib` memilih LibreSSL Apple yang tidak punya `EVP_DigestVerifyUpdate` | soname eksplisit + boot-check `OpenSSL_version` (T-084) |
| Nim | `destroy(true)` menutup socket sebelum drain → klien menerima 0 byte | SIGTERM → `sleep(drain)` → `close()`; T-001/T-060 |
| Nim | `serverThreads` privat; pool "dihitung dari serverThreads" tidak bisa diekspresikan | `workerThreads` eksplisit, pool = N, dicetak di log |
| Nim | `DEFAULT now()` tidak bisa difake; Mummy gzip tanpa `Vary` | lint SQL + `Accept-Encoding: identity` di replayer |
| Nim | `nim check` dan `nim c` berbagi cache dan saling membatalkan | dua direktori nimcache (T-018) |
| Nim | `libpq.dylib` keg-only | `DYLD_FALLBACK_LIBRARY_PATH` + catatan di EXECUTION |
| Abuse | kode share bocor di log Vercel, bukan di app | header `no-store`/`no-referrer`/`noindex` di API + `vercel.json` |
| Abuse | rotasi tidak mencabut karena cache edge dan tanpa `no-store` | §7.6; rotasi = operasi normal |
| Abuse | roster semua komunitas terbaca anonim lewat slug | `/c/{slug}/rankings` khusus anggota; `/s/{code}/rankings` (O-32) |
| Abuse | bucket anon per kode bisa dipakai DoS per tautan | bucket `(template, IP)` + plafon scrape per kode |
| Abuse | join-request membocorkan keberadaan komunitas lewat status/`code` | `202` identik byte-per-byte |
| Abuse | undangan bisa diteruskan menjadi `host` | terikat `email_hash` (O-34) |
| Abuse | merge bisa dipakai mencuri riwayat | admin-only + `merge_log` + audit (O-33) |
| Abuse | tiket WS hidup setelah logout | hapus semua tiket principal |
| Abuse | callback OIDC bisa diputar ulang | `DELETE … RETURNING` sebelum tukar code (D12) |
| Abuse | audit menyimpan kode/email/IP mentah | allowlist field (D13) + metrik berlabel template |
| Abuse | satu body besar bisa menjatuhkan proses | `max_body_bytes`, depth JSON ≤ 16, timeout |
| SRE | `:v1-final` bisa tertimpa saat resume | buat hanya bila belum ada + cek digest |
| SRE | flag cutover tidak dihapus saat gagal → cutover kedua | guard `cutover_state` + hapus di `trap` |
| SRE | reboot di tengah cutover menghidupkan v1 | `cutover.lock`; **diganti putaran 15**: unit v1 di-`disable`, hanya `rollback.sh` yang `enable` |
| SRE | `restore.sh` menolak `bm_staging` | whitelist diperluas |
| SRE | crash loop tanpa alarm | `StartLimit*`, `MemoryMax`, `OnFailure` |
| SRE | `no-store` hanya di Caddy, FE dilayani Vercel | header di `vercel.json` |
| SRE | env hilang = tautan mati permanen | dicatat di runbook + `prod.env.example` memuat role `bm2` |
| SRE | kegagalan ETL tak terlihat (metrik dari app) | probe eksternal + `rows_imported` + OPS-08 |
| QA | gate coverage hanya prosa | T-109 + `coverage-baseline.json` |
| QA | matriks otorisasi bukan artefak | `testdata/authz/matrix.yaml`, route tanpa baris = gagal |
| QA | parity dihitung dari jumlah kasus | ≥1 kasus per operasi + ≥40% status ≥400 |
| QA | `state.json` tidak deterministik (`now()`, uuid) | proyeksi kolom + alias UUID + lint SQL |
| QA | "restore terbukti" pakai stopwatch | `timings.json` per langkah |
| QA | a11y/snapshot tanpa pin font/browser | `deps.lock` + font lokal + `maxDiffPixels: 0` |
| QA | uji entropi kode share tak pernah jalan | N=10⁵ tanpa duplikat + min-entropy |
| QA | pola `git grep` T-082 mustahil hijau | dua grep terpisah + pengecualian path eksplisit |
| QA | skema divergensi tanpa field yang bisa gagal | `expectedDivergence`/`expectNim` + owner |

Yang **ditolak** (dengan alasan, bukan karena tidak nyaman):

| Klaim | Alasan ditolak |
|---|---|
| QA: pola `\.go\b` cocok dengan `logo`/`django` | butuh titik literal sebelum `go`; yang benar hanya bahwa `go build`/`go test` bisa muncul di dokumentasi — diperbaiki dengan mempersempit cakupan path, bukan mengganti regex |
| Abuse: `api.qouver.com` harus menutup semua selain `/ws/*` karena melayani banyak operasi | memanggil API langsung tanpa cookie tidak menambah kemampuan penyerang anonim; yang valid hanya OAuth client terpisah untuk staging dan penghapusan alias saat cutover |
| Internal: "timezone campur" sebagai alasan redesign | dump v1 berisi 27 `timestamptz`, 0 `timestamp without time zone`, 8 `date`; masalahnya konversi `date` WIB, bukan tipe campur — alasan diperbaiki agar tidak menjadi klaim palsu |

Angka akhir putaran 14: task **85**, requirement **68**, operasi **72**, ADR **29**, O-1..O-37.

---

## Putaran 15 — kualitas kode, OWASP, ISO, scrum, PM

Enam review baru (`reviews/round-5-*.md`) menyerang sisi yang belum pernah diuji:
kualitas kode, aturan statis, OWASP/ASVS, ISO, alur scrum, dan manajemen proyek.
Yang diterima:

| Area | Temuan | Perbaikan |
|---|---|---|
| Craft | threadvar `request context` + Mummy multi-thread | `Ctx` eksplisit di handler (T-003/T-009) |
| Craft | `now()` tersembunyi | `now` sebagai parameter + larangan `now()`/`CURRENT_TIMESTAMP` di `modules/**` (T-010) |
| Craft | T-043 mengimpor `tournament` | seam `ratingSource(id)` |
| Craft | `actor_role` tidak ada di audit | D13 |
| Craft | O-38 butuh `DELETE` baris | transisi `approved → released` + `UPDATE … RETURNING` (D15) |
| Sonar | `except Exception` menelan defect | `{.push raises: [].}` + boundary tunggal (T-010) |
| Sonar | `discard` atas hasil DB, `getRow` 0 baris = `""` | update mengembalikan jumlah baris; 0 baris lewat `pqntuples` (T-004/T-010) |
| Sonar | Nim tidak punya `--coverage` (diuji) | gcov via `--passC/--passL`, `LF = 0` menggagalkan gate (T-109) |
| Sonar | `else: discard` pada enum | dilarang; exhaustiveness ditegakkan |
| Sonar | asersi test lemah | hanya `expectProblem(status, code)` (T-010/T-070) |
| Sonar | `trap ERR` inert di `if ! cmd` | `fail()` + `shellcheck` SC2310/2311 (T-011/T-060) |
| Sonar | matriks tanpa dimensi kepemilikan | `self/other/none` (T-020/T-094) |
| Sonar | hash `state.json` bisa konstan pada 0 baris | `rowCount > 0` + self-test mutasi (T-071) |
| OWASP | nonce GCM bisa dipakai ulang saat rotasi | nonce baru + lewati baris yang sudah di kunci aktif (T-024) |
| OWASP | audit bisa diubah aplikasi, tanpa `reason` | grant `INSERT/SELECT` saja + D13/D16 |
| OWASP | JWKS tanpa batas redirect/ukuran/refetch | aturan fetch eksplisit (T-084) |
| OWASP | identifier dinamis (sort/filter) | enum tertutup + archlint (T-008a/T-010) |
| OWASP | retensi audit menyatu dengan data sementara | `audit.retention_days` terpisah (T-105) |
| OWASP | alias staging bertahan | client terpisah + dihapus saat cutover + test origin (T-021) |
| OWASP | antrean klaim tanpa plafon | `security.join_request_rate` + plafon pending (T-048) |
| OWASP | `no-store` tidak menyeluruh | `/auth/me`, `/auth/sessions`, `/c/*` (T-076) |
| ISO | tidak ada prosedur insiden/akses | `docs/ops/operations.md` (T-112) |
| ISO | dasar & retensi data pribadi tidak tertulis | `docs/privacy.md` (T-112) |
| ISO | `date` WIB di-hardcode vs zona komunitas | `local_date` per zona + `tzdata` (T-042/T-064/T-011) |
| ISO | instan tanpa format kontrak | RFC 3339 `Z` (T-008a) |
| ISO | tidak ada exit criteria rilis | OPS-11 + `docs/ops/release.md` (T-107) |
| ISO | MFA/akses tidak pernah disebut | daftar pemegang akses di T-112 |
| Scrum | R0 tanpa perilaku terlihat | walking skeleton + demo di gate R0 (EXECUTION §5) |
| Scrum | FE menunggu binding OpenSSL | T-085 sebelum T-021 |
| Scrum | T-048 tanpa lane | masuk D1 |
| Scrum | O-38 sebagai sel acceptance | task sendiri (T-110) |
| Scrum | fixture peran dibuat setelah T-020 | seed fixture di T-099 sebelum tes matriks |
| PM | halaman FE tanpa pemilik | T-111 (players + admin + setup) |
| PM | review owner = bottleneck | WIP 3 agen / 6 task / 15 menit per task |
| PM | rehearsal tidak pernah menyentuh VPS | rehearsal kedua D-3 + rollback ber-stopwatch |
| PM | `:v1-final` kedaluwarsa tanpa jejak | tanggal hapus + digest diarsipkan (T-082/T-107) |
| PM | dokumen jadi permukaan perubahan | freeze di R0 + anggaran perubahan 10% |

Yang **ditolak**:

| Klaim | Alasan |
|---|---|
| Craft: 9 modul → 5, registry tanpa plafon, 5 migrasi → 1–2 berkas | membongkar keputusan yang sudah jadi; jumlah modul/berkas bukan sumber kompleksitas, sedangkan plafon L2 adalah jaminan yang diminta pemilik |
| Craft: buang emitter client TS, sisakan `schema.d.ts` | kontrak FE↔API adalah satu-satunya cara mencegah drift; emitter dipertahankan |
| Craft: hapus D1 | D1 mencatat bug urutan migrasi nyata yang membuat DB kosong gagal |
| OWASP: cosign untuk image | digest + tag SSH-signed + token GHCR sudah memberi integritas/autentisitas sepadan; cosign menambah kunci dan langkah verifikasi tanpa menghapus ancaman nyata |
| Sonar: *indent walker* 150 baris sebagai gate R0 | alat baru harus dirawat sebelum ada kode yang diukur; batas ukuran/complexity dijadikan opsional |
| Scrum: pecah T-060 jadi tiga, lipat delapan task "noise" | mengganti penomoran 85 task tanpa keuntungan setara; masalah nyata (backup sebelum ETL) diselesaikan dengan urutan |
| PM: cap 2 agen | 3 agen cukup untuk paralelisme yang direncanakan tanpa melampaui kapasitas review |

Keputusan pemilik yang masuk: **O-38** (lepas klaim + klaim ulang tanpa cooldown),
**O-39** (cutover manual), **O-40** (semua halaman FE diport).

Angka akhir putaran 15: task **88**, requirement **72**, operasi **73**, ADR **31**, O-1..O-40.

---

## Putaran 16 — keputusan penutup (interaktif, 2026-11-03)

Tujuh pertanyaan terbuka dari audit putaran 15 dijawab pemilik. Tidak ada yang
menambah task atau operasi; dua mengubah jangka waktu, satu mengubah titik beku
dokumen.

| Pertanyaan | Jawaban | Konsekuensi |
|---|---|---|
| Hotfix P0 di v1? | **Tidak**, tetap O-8 | Eksposur berlanjut sampai v2 live; dicatat sebagai risiko sadar dengan estimasi 3–5 bulan, bukan asumsi "cepat" |
| Hosting FE? | **Tetap Vercel** | Proxy, header `vercel.json`, alias staging, dan log Vercel tetap dirawat; diterima sebagai kompleksitas |
| Lingkup 2.0.0? | **Penuh**, tanpa pemotongan | 88 task; tidak ada fitur v1 yang hilang |
| Retensi v1? | **30 hari + arsip tarball** | O-29/ADR-026 diperbarui; D+14 → D+30 |
| Database `bm`? | **Simpan permanen** sebagai arsip read-only | O-41; T-082 tidak menyentuh `bm` |
| Notifikasi? | **Manual** | O-42; antrean join/klaim hanya di UI admin |
| Backup off-box? | **Tetap di VPS** | O-23 dipertahankan; risiko disk tetap diterima |
| Freeze dokumen? | **Di R0** | O-43; perubahan setelah walking skeleton hanya lewat kontrak/matriks/backlog |

Angka akhir: task **88**, requirement **72**, operasi **73**, ADR **31**, O-1..O-43.

---

## Putaran 17 — gate final sebelum beku

Tujuh reviewer independen dengan mandat sempit: cari drift dan ketidakbisaan
eksekusi, bukan ide baru. Temuan hanya dihitung bila (a) dua dokumen bertentangan
sehingga agen akan salah implementasi, (b) acceptance tidak bisa dijalankan, atau
(c) angka/link rusak.

| Reviewer | Verdict | Temuan blocking yang diterapkan |
|---|---|---|
| Drift | READY WITH FIXES | `72→73` di §5 dan tabel parity; ADR-022/§5 masih "satu push"; `426→410`; O-10 ganda; T-008b `10→14`; `CUTOVER=1`/`ConditionPathExists`/`cutover.request` dibersihkan; `share_links`/`public_id` ditandai ditolak di memo 03 |
| Traceability | READY WITH FIXES | 15 acceptance cell yang lolos dengan stub 200 ditulis ulang menjadi bisa gagal (T-025/029/030/040/044/045/046/047/052/070/078/090/093/094/102) |
| R0 simulation | READY WITH FIXES | Kontrak runtime (`MAJADU_PORT`, `/healthz`, `/readyz`, drain), `./task` (nama target = nama berkas, env, exit), `config.nims` (`thisDir()`), `Ctx`, API DB (`$1..$n`, `Option`, `tx`), DSN/role dev, `deps.lock` |
| Security | READY WITH FIXES | Release/approve memakai `FOR UPDATE` + `UPDATE … RETURNING` (0 baris → 409); admin tidak memutuskan klaim sendiri; `reason` `self_released`; audit `target_kind='claim'`; invite `token_hash`; fallback pasca-cutover `:prev`; `REVOKE` + `CONNECT` untuk `bm`; dump final di luar rotasi; `no-store` diperluas |
| Ops | READY WITH FIXES | `:v1-final` dibuat **sebelum** v1 dihentikan; rollback menghapus `cutover_state`; guard memeriksa `completed_at`; T-060 bergantung T-103; deploy tanpa path filter + membaca `VERSION`; T-063 dipisah (rehearsal ≤ 30 menit, jendela ≤ 10 menit); D-3 dijadwalkan |
| Schema | READY WITH FIXES | D2/D3/D5/D6/D13/D14/D15/D16 diberi acceptance katalog (`pg_indexes`, `pg_attrdef`, `has_table_privilege`); `audit.retention_days` masuk registry; pembersih audit jadi tool `bm2_owner` |
| Nim | READY WITH FIXES | `thisDir()` bukan `$projectDir`; `libcrypto.dylib` generik meng-abort saat load; `EVP_PKEY_assign(pkey, 6, rsa)`; `--lineTrace:on`; klaim suffix `_check`/`_r` dihapus; prasyarat `gcovr`/`lcov` dicatat |

Temuan yang **ditolak**: menaikkan batas agen dari 3 menjadi 4 (WIP tetap 3 aktif,
6 task berjalan). Temuan yang **ditunda**: seluruh usulan yang menambah
task/requirement/operasi — itu masuk 2.1, bukan gate ini.

Kedua checker (`audit_plan.py`, `check2.py`) bersih setelah perbaikan. Angka tidak
berubah dari putaran 16: **88 task, 72 requirement, 73 operasi, 31 ADR, O-1..O-43**.

---

## Yang sudah diputuskan (tidak lagi terbuka)

| Pertanyaan | Keputusan |
|---|---|
| Jendela P0 terbuka | diterima apa adanya (ADR-011) |
| Penonton menulis | tidak |
| Host tanpa login | tidak; semua penulis login Google |
| Impor data v1 | ETL sekali saat cutover |
| Verifikasi RS256 | modul binding OpenSSL |
| Peran `member` | R2 |
| Multi-komunitas | masuk repo ini; isolasi `community_id` + FK komposit; poin per komunitas; akun global |
| Frontend | React 19 + Vite + Tailwind 4 dibekukan (tanpa Svelte) |
| Parameter | semua angka bisnis dari DB, berlapis platform → komunitas |
| Database | `bm2` sebagai database terpisah + role `bm2_app` |
| Papan peringkat | anggota via `/c/{slug}/rankings`, penonton via `/s/{code}/rankings`; tanpa kode → 404 (O-32) |
| Klaim pemain | semua lewat persetujuan `admin`; merge admin-only + `merge_log` (O-33) |
| Undangan | terikat email (O-34) |
| Masa berlaku tautan | tanpa kedaluwarsa otomatis; hanya dicabut/dirotasi (O-35) |
| Gate coverage | 90/75 ratchet dengan baseline; `check` tetap tanpa DB (O-36) |
| Step-up auth | tidak perlu; diganti daftar sesi + revoke-all + audit (O-37) |
| Lepas klaim lalu klaim ulang | boleh, tanpa cooldown, tetap lewat persetujuan admin (O-38) |
| Pemicu cutover | manual lewat `cutover.sh` (O-39) |
| Halaman FE lama | semua diport, satu task (O-40) |
| Database `bm` | disimpan permanen sebagai arsip read-only (O-41) |
| Notifikasi | tidak ada di 2.0.0; manual (O-42) |
| Freeze dokumen | setelah R0 (O-43) |
| P0 v1 | tetap terbuka (O-8 ditinjau ulang) |
| Hosting FE | tetap Vercel (O-22) |
| Backup | tetap di VPS (O-23) |

Sisa risiko yang **tidak** diselesaikan keputusan ini: enumerasi `GET /sessions`
dan mutasi skor anonim tetap terbuka sampai API Nim rilis (lihat TECH-SPEC §7.5).

---

## Batas kepercayaan dokumen ini

- Klaim baris 1–19 diuji pada 2026-11-03; setelah kode berubah, klaim bisa kedaluwarsa.
- Angka performa (p95, RSS, waktu compile) adalah **target**, bukan hasil pengukuran.
- Estimasi kapasitas agen (3 aktif, 6 task berjalan) adalah heuristik, belum divalidasi pada repo ini.
