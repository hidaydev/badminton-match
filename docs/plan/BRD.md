# BRD — Majadu Backend Rewrite (Nim)

Status: draft untuk review pemilik
Tanggal: 2026-11-03
Pemilik: solo maintainer (Fredi)
Repo: `badminton-match` (publik) — pekerjaan berjalan lokal, tanpa push sampai stabil

> **Istilah.** `v1` = backend Go yang berjalan sekarang di repo ini. `v2` = backend
> Nim penggantinya **di repo yang sama**. `majadu` adalah proyek terpisah dan
> **tidak disentuh** (O-1).

---

## 1. Konteks bisnis

Majadu adalah aplikasi operasional badminton yang dipakai rutin: menyusun jadwal
doubles yang adil, menjalankan skor courtside, mencatat kehadiran, menghitung poin
peringkat, dan mengelola turnamen. Produk berjalan di produksi (VPS untuk API,
Vercel untuk web) dan sudah dipakai dengan data nyata.

Audit 2026-11-03 menemukan tiga hal yang menentukan arah bisnis:

1. **Ada lubang keamanan aktif.** `GET /sessions` membocorkan `share_code` seluruh
   sesi, dan share code adalah kunci tulis anonim (`PUT`/`PATCH`/`absent`/`swap`).
   Terpisah dari itu, `POST /sessions` dan `POST /tournaments` anonim memicu
   auto-lock → ingest poin otomatis, sehingga peringkat bisa dipalsukan tanpa login.
2. **Biaya perubahan di Go tinggi.** Coverage 14,6%, 249/347 fungsi tanpa test,
   56 dari 74 test store selalu skip, dan tiga salinan aturan skor (Go, web,
   scoreboard) sehingga perbaikan harus dilakukan berulang.
3. **Dokumentasi tidak lagi menjadi kontrak.** OpenAPI mencakup 16 dari 48 route,
   dan dokumen masih menjual Glicko yang sudah pensiun.

Keputusan pemilik: **rewrite backend ke Nim di repo ini**, kontrak boleh berubah,
frontend ikut dikerjakan, autentikasi pindah ke Google.

Keputusan pemilik berikutnya (2026-11-03): **produk menjadi multi-komunitas**.
Satu instance melayani beberapa komunitas badminton, dengan data, anggota, dan papan
poin yang terpisah per komunitas. Ini bukan fitur tambahan di akhir — ia mengubah
bentuk skema, auth, routing, dan sebagian besar requirement.

## 2. Tujuan bisnis

| # | Tujuan | Ukuran keberhasilan |
|---|--------|---------------------|
| B1 | Menutup seluruh temuan keamanan P0/P1 | 0 P0 & 0 P1 terbuka pada rilis cutover, diverifikasi test bernama |
| B2 | Satu sumber kebenaran aturan main | Aturan skor/poin/generator hanya ada di backend; frontend tidak memvalidasi |
| B3 | Menurunkan biaya perubahan | Menambah satu endpoint = 1 modul + 1 test + 1 entri kontrak, tanpa menyentuh 3 bahasa |
| B4 | Rilis bisa dipercaya | Deploy gagal selalu rollback otomatis; tidak ada rilis yang hilang senyap |
| B5 | Perilaku tidak berubah tanpa sengaja | Parity harness Go↔Nim lulus dengan divergensi yang dideklarasikan eksplisit |
| B6 | Maintainer tunggal tetap sanggup | `./task check` ≤ 60 s, `./task verify` ≤ 5 min, tanpa ritual manual |
| B7 | Satu instance melayani banyak komunitas | Komunitas baru bisa dibuat tanpa deploy; data & poin tidak pernah tercampur |
| B8 | Aturan bisa diubah tanpa deploy | Mengubah ambang/poin/format/limit = satu baris DB + audit, tanpa rilis |

## 3. Stakeholder

| Peran | Kepentingan |
|-------|-------------|
| Pemilik/maintainer | Biaya perawatan, keamanan, kecepatan rilis |
| Host sesi (admin lapangan) | Login cepat, bisa mengubah skor courtside tanpa gesekan |
| Pemain | Papan peringkat yang adil dan tidak bisa dimanipulasi |
| Penonton (share link) | Bisa melihat sesi berjalan tanpa akun |
| Pemilik server | Tidak ada perubahan pada v1 selama rewrite; tidak ada downtime tak terencana |

## 4. Ruang lingkup

**Termasuk**
- **Multi-komunitas**: komunitas, keanggotaan, peran per komunitas, isolasi data,
  routing `/c/{slug}`, papan poin per komunitas.
- Rewrite backend ke Nim: 48 route v1 dipetakan ke permukaan v2 (keep/ubah/hapus/tambah).
- Autentikasi Google (OIDC) + model peran; pemisahan tegas baca publik vs tulis terautentikasi.
- Rework frontend yang terdampak perubahan kontrak dan auth.
- **Database baru `bm2`** (terpisah dari `bm`, role sendiri) + ETL sekali saat cutover, ketika v1 dibekukan.
- Pipeline CI/CD, image, deploy, rollback, observability.
- Test: unit, property, integrasi DB, kontrak, parity, E2E, a11y.
- Dokumentasi: PRD/BRD/TECH-SPEC/BACKLOG, ADR, OpenAPI sebagai kontrak.

**Tidak termasuk (fase ini)**
- Billing, notifikasi email/push, aplikasi mobile native.
- Mengganti v1 di produksi sebelum pemilik menyatakan stabil.
- Perubahan aturan poin peringkat (model 12 minggu / best 10 dipertahankan).

## 5. Asumsi

- v1 tetap melayani produksi selama rewrite; tidak ada perubahan DDL pada `bm`.
- Data produksi tidak pernah masuk repo; dump hanya untuk pengembangan lokal.
- Server hanya dipakai untuk referensi skema dan (nanti) deploy, bukan tempat eksperimen.
- Satu maintainer + subagent paralel; tidak ada tim penuh waktu.
- Konvensi bahasa: identifier/komentar kode Inggris; dokumen internal Indonesia.

## 6. Batasan (constraints)

| # | Batasan | Konsekuensi |
|---|---------|-------------|
| C1 | Repo publik | Tidak boleh ada secret, IP asli, dump skema, atau data pribadi di git |
| C2 | Kerja lokal, tanpa push sampai stabil | Butuh rehearsal deploy lokal yang meniru produksi |
| C3 | v1 tetap hidup | Tidak boleh memaksa migrasi data dini; skema v2 harus bisa hidup berdampingan |
| C4 | Nim 2.4.x | Pilihan library dan memory manager terbatas pada yang terbukti |
| C5 | Satu instance API | Realtime boleh in-memory, tapi tidak boleh mengklaim durable |
| C6 | Windows/macOS dev | Build & test harus jalan di macOS arm64 tanpa dependensi OS khusus |
| C7 | **Frontend stack dibekukan**: React 19 + Vite + Tailwind 4 + React Query + Zustand + react-router | Tidak ada rewrite ke Svelte/framework lain; pekerjaan FE hanya menyesuaikan kontrak, auth, dan multi-komunitas |
| C8 | **Tidak ada angka/aturan bisnis hardcoded** | Semua parameter bisnis dibaca dari DB (default platform + override komunitas); mengubah nilai tidak boleh butuh deploy |

## 7. Risiko bisnis

| # | Risiko | Dampak | Mitigasi |
|---|--------|--------|----------|
| R1 | P0 tetap terbuka selama rewrite, **tanpa kontrol kompensasi** (keputusan pemilik, O-4/O-8) | Manipulasi skor/poin oleh pihak yang tahu URL; enumerasi seluruh sesi | Diterima sadar. Dicatat di `ADR-011` beserta cara mencabutnya bila berubah pikiran. Tidak ada perubahan pada v1. |
| R2 | Scope creep (auth + kontrak + FE + skema + CI sekaligus) | Rewrite tidak selesai | Rilis bertahap R0–R4, tiap tahap punya gate yang bisa dihentikan |
| R3 | Kontrak berubah saat FE belum siap | FE rusak, kerja serial | Kontrak dibekukan lebih dulu + mock API di hari pertama |
| R4 | Redesign skema menghilangkan data | Kehilangan riwayat pertandingan | Import hanya setelah verifikasi rekonsiliasi; `bm` tidak disentuh |
| R5 | Rewrite menyalin bug v1 sebagai "spesifikasi" | Kerentanan ikut pindah | Divergensi wajib dideklarasikan di parity harness |
| R6 | Deploy baru belum pernah gagal | Rollback tidak teruji | Failure injection wajib di rehearsal lokal |
| R7 | Kebocoran data antar komunitas (query lupa filter `community_id`) | Kepercayaan hancur; data komunitas lain terlihat | FK komposit + context wajib + suite cross-tenant; query tanpa scope = error kompilasi/runtime |
| R8 | Scope bertambah (auth + kontrak + FE + skema + multi-komunitas) | Rewrite tidak selesai | Rilis bertahap; multi-komunitas masuk R1, bukan ditunda |
| R9 | Data v1 tidak punya konsep komunitas | Import ambigu | Semua data v1 dipetakan ke satu komunitas default saat impor |

## 8. Definisi sukses

Rewrite dinyatakan selesai bila **semua** terpenuhi:

1. Seluruh route v2 berjalan di Nim, tanpa satu pun handler Go tersisa.
2. Parity harness lulus; setiap divergensi punya alasan tertulis dan test yang
   memastikan divergensi itu tetap terjadi (mis. `share_code` tidak lagi bocor).
3. Security suite lulus: IDOR, eskalasi peran, CSRF, rate limit, replays OAuth.
4. CI hijau dari commit bersih, tanpa test yang di-skip karena DB tidak ada.
5. Deploy rehearsal berhasil, termasuk skenario build gagal dan health gagal → rollback.
6. `docs/` akurat: OpenAPI = 100% route, tidak ada dokumen yang menjual fitur mati.
7. Tidak ada secret/​dump/​IP di riwayat git.

## 9. Keputusan pemilik yang sudah final

| ID | Keputusan |
|----|-----------|
| O-1 | Rewrite dilakukan di repo `badminton-match`, bukan di `majadu` v2 |
| O-2 | Kontrak API boleh berubah; frontend ikut dikerjakan |
| O-3 | Auth: passwordless Google (OIDC), bukan magic link, bukan admin token statis |
| O-4 | P0 diperbaiki sekali di Nim (tidak ada hotfix Go) |
| O-5 | DB dev/test: PostgreSQL lokal (Homebrew 18.6 sudah berjalan; Podman opsional bila terpasang) + dump skema |
| O-6 | Blueprint stack dipilih berdasarkan bukti, bukan preferensi |
| O-7 | Tidak ada push ke remote sampai seluruh rangkaian stabil |
| O-8 | P0 diterima terbuka selama rewrite; tidak ada hotfix Go dan tidak ada kontrol kompensasi |
| O-9 | Tautan "Lihat" hanya untuk membaca; **semua penulis wajib login Google** (tidak ada `edit_code`) |
| O-10 | **Cutover instan**: satu push ke `main` = v2 live. Data v1 dipindahkan ke `bm2` **sebelum** push (pra-impor saat v1 masih melayani); tidak ada masa berdampingan |
| O-11 | Peran `member` masuk R2, bukan R1 |
| O-12 | Verifikasi ID token RS256 dibangun sebagai modul binding OpenSSL lokal (ADR-009 diterima) |
| O-13 | Multi-komunitas masuk repo ini, bukan diserahkan ke majadu v2 |
| O-14 | Isolasi data: satu database `bm2`, kolom `community_id` NOT NULL, FK komposit untuk relasi NOT NULL |
| O-15 | Papan poin dihitung per komunitas, bukan global |
| O-16 | Akun global (satu Google untuk semua komunitas), peran berlaku per komunitas |
| O-17 | Frontend tetap React 19 + Vite + Tailwind 4; **tidak ada rewrite ke Svelte** atau framework lain |
| O-18 | Semua parameter/aturan bisnis disimpan di DB, bukan di kode; nilai bisa diubah tanpa deploy |
| O-19 | Parameter berlapis: default platform, lalu override per komunitas; komunitas tidak bisa melewati batas aman yang ditetapkan platform |
| O-20 | Boleh membuat **database baru `bm2`** di instance PostgreSQL yang sama; arsitektur DB dirancang ulang, bukan diturunkan dari `bm` |
| O-21 | Antarmuka berbahasa **Inggris**; kunci i18n disiapkan agar bahasa lain bisa ditambah tanpa mengubah komponen |
| O-22 | FE tetap `majadu.vercel.app`; HTTP ke API lewat rewrite proxy same-origin `/api/*`; WebSocket langsung dengan tiket sekali pakai |
| O-23 | Backup: `pg_dump` harian `bm` + `bm2`, retensi 7 hari, snapshot wajib sebelum impor, restore diuji |
| O-24 | Versioning SemVer otomatis dari Conventional Commits; `VERSION` satu sumber; tag SSH-signed annotated + GitHub Release |
| O-25 | Rilis publik pertama bernomor **2.0.0** (menandai generasi, bukan lanjutan v1); tidak ada fase 0.x |
| O-26 | Peran: `platform_owner` global (dewa, satu akun) + `admin`/`host`/`member` per komunitas; tanpa `owner` per komunitas; platform owner **boleh bergabung** sebagai anggota biasa untuk bermain |
| O-27 | Kode share disimpan terenkripsi agar `admin`/`host` bisa menampilkannya lagi, dengan audit setiap penampilan |
| O-28 | Image dibangun sekali di CI pada tag dan dideploy berdasarkan digest; deploy tidak rebuild |
| O-29 | Image `:v1-final` dipertahankan 14 hari di luar rotasi `:local`/`:prev` sebagai jalur rollback |

### Keterlacakan: di mana tiap keputusan diwujudkan

| Keputusan | Wujud konkret | Task |
|---|---|---|
| O-1 | Seluruh kode baru di `apps/api/`, `modules/`, `shared/` repo ini; tidak ada sentuhan ke `majadu` | T-001 |
| O-2 | Kontrak v2 ditulis ulang (48 → 63 operasi); FE ikut dirombak | T-008a/b, T-028–T-030, T-101 |
| O-3 | OIDC Google; tidak ada magic link / token admin | T-021, T-084 |
| O-4 | Tidak ada commit perbaikan di `apps/api/internal/`; P0 ditutup di Nim | T-021, T-023, T-025 |
| O-5 | `./task dev-db` memakai cluster lokal; container hanya fallback | T-007 |
| O-6 | Setiap klaim stack diuji di `CROSS-CHECK.md` (putaran 8) dan memo | — (dokumen) |
| O-7 | Protokol merge lokal; tidak ada push sampai R4 | seluruh backlog §0 butir 8 |
| O-8 | ADR-011 menerima P0 terbuka; tidak ada kontrol kompensasi di kode | T-083 |
| O-9 | `session.links` read-only, tanpa `kind`; semua tulis butuh principal | T-024, T-023 |
| O-10 | Pra-impor ke `bm2` sebelum push; satu push = cutover; rollback ke image v1 | T-064, T-065, T-060 |
| O-10 | Tautan `/s/{code}` lama tidak dipertahankan; kode baru per sesi | T-024, T-064 |
| O-11 | `member` tidak dipakai di R1; masuk R2 | T-048 |
| O-12 | Binding OpenSSL + cek `libcrypto` saat boot | T-084 |
| O-13 | 9 modul termasuk `modules/community/`; 10 route komunitas | T-090–T-093 |
| O-14 | `community_id NOT NULL`, FK komposit untuk relasi NOT NULL, UNIQUE scoped | T-006a–e |
| O-15 | `rating_events`/`deltas`/`players` ber-`community_id`; papan per komunitas | T-042–T-044 |
| O-16 | `platform.user` global; peran di `community.membership` | T-020, T-091 |
| O-17 | Frontend tetap React 19 + Vite + Tailwind 4; tidak ada dependensi Svelte | T-028 |
| O-18 | Tidak ada konstanta bisnis di kode; `archcheck` memindai literal | T-096, T-098 |
| O-19 | Resolusi `L2 → L1 → error`, plafon L1 divalidasi saat tulis | T-096, T-097 |
| O-20 | Database `bm2` + role `bm2_app`; `bm` nol DDL | T-007, T-005 |
| O-21 | Inggris sebagai bahasa UI; kunci i18n di kontrak dan komponen | T-028, T-029, T-030 |
| O-22 | `apps/web/vercel.json` rewrite + endpoint `ws-ticket` + `security.allowed_origins` | T-028, T-027, T-076 |
| O-23 | Skrip dump harian + latihan restore + snapshot pra-impor | T-060, T-063, T-064 |
| O-24 | `./task release`, `VERSION`, CHANGELOG, tag SSH-signed, workflow Release | T-107 |
| O-25 | `VERSION` dimulai dari `2.0.0`; bump pertama menghasilkan `2.0.x`/`2.x.0`/`3.0.0` | T-107 |
| O-26 | Matriks kapabilitas, RBAC middleware, peran per keanggotaan, join platform owner | T-023, T-020, T-090, T-091 |
| O-27 | `session.links.code_enc` + endpoint tampil-ulang + audit | T-024, T-006a |
| O-28 | Build image di workflow rilis, deploy by digest | T-107, T-060 |
| O-29 | Tag `:v1-final` + pengecualian rotasi di `deploy-vps.sh` | T-060, T-082 |

## 10. Jawaban pemilik (2026-11-03)

| Pertanyaan | Jawaban | Konsekuensi |
|---|---|---|
| Jendela P0 terbuka | Diterima apa adanya, tanpa kontrol tambahan | Tidak ada perubahan v1; risiko dicatat di ADR-011 |
| Penonton menulis? | Tidak — tautan "Lihat" hanya baca | `view_code` murni read-only |
| Host tanpa login? | Tidak — semua penulis login Google | `edit_code` dihapus dari desain; model kapabilitas menyusut |
| Impor data v1 | Pra-impor ke `bm2`, lalu satu push | Cutover instan; tidak ada jendela data kosong; kehilangan baris antara pra-impor dan push dicatat di runbook |
| Verifikasi RS256 | Bangun modul binding OpenSSL | ADR-009 diterima; menambah satu task teknis |
| Peran `member` | Masuk R2 | R1 hanya `owner`/`admin`/`host` |
| Multi-komunitas | Masuk repo ini, `community_id` + FK komposit, poin per komunitas, akun global | Skema, auth, routing, dan backlog berubah (lihat §9 O-13..O-16) |

Tidak ada pertanyaan terbuka yang tersisa untuk fase perencanaan.
