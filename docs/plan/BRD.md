# BRD — Majadu Backend Rewrite (Nim)

Status: draft untuk review pemilik
Tanggal: 2026-11-03
Pemilik: solo maintainer (Fredi)
Repo: `badminton-match` (publik) — pekerjaan berjalan lokal, tanpa push sampai stabil

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

## 2. Tujuan bisnis

| # | Tujuan | Ukuran keberhasilan |
|---|--------|---------------------|
| B1 | Menutup seluruh temuan keamanan P0/P1 | 0 P0 & 0 P1 terbuka pada rilis cutover, diverifikasi test bernama |
| B2 | Satu sumber kebenaran aturan main | Aturan skor/poin/generator hanya ada di backend; frontend tidak memvalidasi |
| B3 | Menurunkan biaya perubahan | Menambah satu endpoint = 1 modul + 1 test + 1 entri kontrak, tanpa menyentuh 3 bahasa |
| B4 | Rilis bisa dipercaya | Deploy gagal selalu rollback otomatis; tidak ada rilis yang hilang senyap |
| B5 | Perilaku tidak berubah tanpa sengaja | Parity harness Go↔Nim lulus dengan divergensi yang dideklarasikan eksplisit |
| B6 | Maintainer tunggal tetap sanggup | `./task check` ≤ 60 s, `./task verify` ≤ 5 min, tanpa ritual manual |

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
- Rewrite backend ke Nim: 48 route v1 dipetakan ke permukaan v2 (keep/ubah/hapus/tambah).
- Autentikasi Google (OIDC) + model peran; pemisahan tegas baca publik vs tulis terautentikasi.
- Rework frontend yang terdampak perubahan kontrak dan auth.
- Skema data baru (`bm2`) + jalur impor dari `bm`, dijalankan setelah stabil.
- Pipeline CI/CD, image, deploy, rollback, observability.
- Test: unit, property, integrasi DB, kontrak, parity, E2E, a11y.
- Dokumentasi: PRD/BRD/TECH-SPEC/BACKLOG, ADR, OpenAPI sebagai kontrak.

**Tidak termasuk (fase ini)**
- Multi-community / multi-tenant (itu domain majadu v2, bukan repo ini).
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

## 7. Risiko bisnis

| # | Risiko | Dampak | Mitigasi |
|---|--------|--------|----------|
| R1 | P0 tetap terbuka selama rewrite, **tanpa kontrol kompensasi** (keputusan pemilik, O-4/O-8) | Manipulasi skor/poin oleh pihak yang tahu URL; enumerasi seluruh sesi | Diterima sadar. Dicatat di `ADR-011` beserta cara mencabutnya bila berubah pikiran. Tidak ada perubahan pada v1. |
| R2 | Scope creep (auth + kontrak + FE + skema + CI sekaligus) | Rewrite tidak selesai | Rilis bertahap R0–R4, tiap tahap punya gate yang bisa dihentikan |
| R3 | Kontrak berubah saat FE belum siap | FE rusak, kerja serial | Kontrak dibekukan lebih dulu + mock API di hari pertama |
| R4 | Redesign skema menghilangkan data | Kehilangan riwayat pertandingan | Import hanya setelah verifikasi rekonsiliasi; `bm` tidak disentuh |
| R5 | Rewrite menyalin bug v1 sebagai "spesifikasi" | Kerentanan ikut pindah | Divergensi wajib dideklarasikan di parity harness |
| R6 | Deploy baru belum pernah gagal | Rollback tidak teruji | Failure injection wajib di rehearsal lokal |

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
| O-5 | DB dev/test: PostgreSQL lokal via Podman + dump skema |
| O-6 | Blueprint stack dipilih berdasarkan bukti, bukan preferensi |
| O-7 | Tidak ada push ke remote sampai seluruh rangkaian stabil |
| O-8 | P0 diterima terbuka selama rewrite; tidak ada hotfix Go dan tidak ada kontrol kompensasi |
| O-9 | Tautan "Lihat" hanya untuk membaca; **semua penulis wajib login Google** (tidak ada `edit_code`) |
| O-10 | v2 rilis dengan data kosong; impor v1 dijalankan setelah stabil |
| O-11 | Peran `member` masuk R2, bukan R1 |
| O-12 | Verifikasi ID token RS256 dibangun sebagai modul binding OpenSSL lokal (ADR-009 diterima) |

## 10. Jawaban pemilik (2026-11-03)

| Pertanyaan | Jawaban | Konsekuensi |
|---|---|---|
| Jendela P0 terbuka | Diterima apa adanya, tanpa kontrol tambahan | Tidak ada perubahan v1; risiko dicatat di ADR-011 |
| Penonton menulis? | Tidak — tautan "Lihat" hanya baca | `view_code` murni read-only |
| Host tanpa login? | Tidak — semua penulis login Google | `edit_code` dihapus dari desain; model kapabilitas menyusut |
| Impor data v1 | Kosong dulu, impor setelah stabil | Cutover tidak menunggu ETL; T-064 bisa berjalan pasca-rilis |
| Verifikasi RS256 | Bangun modul binding OpenSSL | ADR-009 diterima; menambah satu task teknis |
| Peran `member` | Masuk R2 | R1 hanya `owner`/`admin`/`host` |

Tidak ada pertanyaan terbuka yang tersisa untuk fase perencanaan.
