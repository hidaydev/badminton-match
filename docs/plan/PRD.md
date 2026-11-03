# PRD — Majadu v2 Backend (Nim)

Status: draft untuk review pemilik
Tanggal: 2026-11-03
Rujukan: `BRD.md`, `TECH-SPEC.md`, `BACKLOG.md`, `memos/*`

---

## 1. Ringkasan produk

Majadu berubah dari "aplikasi Go yang dipelihara sambil diperbaiki" menjadi
**Nim service dengan kontrak eksplisit, auth nyata, dan aturan main yang hanya
hidup di satu tempat**. Frontend ikut dirapikan karena beberapa flow berubah
(login Google, share link baca/tulis, realtime).

Yang **tidak** berubah: cara host menjalankan sesi badminton. Setup → generate →
skor courtside → publish → papan peringkat. Semua perubahan teknis harus
menjaga alur lapangan tetap cepat.

## 2. Persona & jobs-to-be-done

| Persona | Peran teknis | JTBD |
|---------|--------------|------|
| **Host** (admin lapangan) | `host` — login Google | Menyiapkan sesi, membagikan tautan, mengoreksi skor di lapangan dalam hitungan detik |
| **Penonton** | tanpa akun, `view_code` | Melihat skor dan jadwal berjalan tanpa bisa mengubah apa pun |
| **Pemain** | `member` (opsional) | Melihat poin, riwayat, badge; mempercayai bahwa poin tidak bisa dipalsukan |
| **Owner** | `owner` | Menjalankan operasi admin: merge pemain, rebuild poin, hapus turnamen |
| **Community owner/admin** | `owner`/`admin` per komunitas | Mengelola anggota, peran, pengaturan komunitas, undangan |
| **Anggota multi-komunitas** | satu akun, banyak komunitas | Berpindah komunitas tanpa login ulang; poin tiap komunitas terpisah |
| **Platform owner** | `platform_owner` | Membuat komunitas baru; tidak otomatis menjadi anggota komunitas itu |
| **Maintainer** | — | Mengubah satu aturan tanpa menyentuh tiga bahasa |

## 3. Rencana rilis

| Rilis | Isi | Gate keluar |
|-------|-----|-------------|
| **R0 — Fondasi** | Kontrak v2, skeleton Nim, local DB, parity harness, CI | `./task check` hijau; corpus parity bisa direkam; DB lokal naik < 20 s |
| **R1 — Auth, komunitas & sesi** | OIDC Google, sesi/role, komunitas + keanggotaan + routing `/c/{slug}`, tautan baca `view_code`, baca+tulis sesi (login-only), WebSocket live | Isolasi cross-tenant lulus; 3 sesi nyata berjalan di E2E |
| **R2 — Pemain & poin** | Player CRUD/merge, papan poin, achievement, ingest/revert/rebuild, **peran `member` + klaim profil** | Parity poin identik dengan v1 pada fixture yang sama |
| **R3 — Turnamen & ekspor** | Classic + team tournament, social export | Bracket & standings parity; export tervisualkan |
| **R4 — Cutover** | Deploy rehearsal, rollback drill, migrasi data | Failure injection lulus; owner menyatakan siap |

Aturan: **tidak ada rilis yang dimulai sebelum gate rilis sebelumnya lulus.**
Pekerjaan dalam satu rilis boleh paralel (lihat `BACKLOG.md`).

## 4. Functional requirements

Prioritas: **M** = must, **S** = should, **C** = could. Acceptance ditulis
sebagai kondisi yang bisa diuji otomatis.

### 4.0 Komunitas

Komunitas adalah **batas data**, bukan sekadar label. Setiap sesi, pemain,
turnamen, tautan, dan poin milik tepat satu komunitas.

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| COM-01 | M | Buat komunitas dengan slug unik | Slug bentrok → 409; slug tidak valid → 400 |
| COM-02 | M | Bergabung lewat undangan sekali pakai, berbatas peran & waktu | Undangan dipakai dua kali → gagal; kedaluwarsa → gagal |
| COM-03 | M | Peran berlaku per komunitas: `owner`/`admin`/`host`/`member` | Peran di komunitas A tidak memberi hak di komunitas B |
| COM-04 | M | Isolasi data antar komunitas | Request lintas komunitas → **404**, bukan 403; query tanpa `community_id` ditolak |
| COM-05 | M | Konteks komunitas di URL: web `/c/{slug}/…`, API `/c/{slug}/api/…` | Route komunitas tanpa slug → 404 |
| COM-06 | M | Pengguna bisa berpindah komunitas tanpa login ulang | Daftar "komunitas saya"; pilihan tersimpan |
| COM-07 | S | Pengaturan komunitas: nama, zona waktu, parameter poin, nama lapangan default | Perubahan berlaku tanpa deploy; tercatat di audit |
| COM-08 | C | Direktori komunitas publik | Default mati; bila dinyalakan, hanya slug + nama yang tampil |
| COM-09 | M | Satu akun Google untuk semua komunitas | Tidak ada akun ganda untuk orang yang sama |
| COM-10 | S | Keluar/dikeluarkan dari komunitas mencabut akses seketika | Request berikutnya → 404/401, bukan cache lama |

### 4.1 Autentikasi & otorisasi

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| AUTH-01 | M | Login hanya lewat Google OIDC (Authorization Code + PKCE) | Login berhasil dengan akun Google; `state`/`nonce` salah ditolak 400 tanpa membuat sesi |
| AUTH-02 | M | Tidak ada token di JavaScript | Cookie sesi `HttpOnly`; tidak ada access token di localStorage/sessionStorage |
| AUTH-03 | M | Peran per komunitas: `owner`, `admin`, `host`, `member`; `platform_owner` global | Matriks route×role×komunitas diuji; belum login → 401, peran kurang → 403, beda komunitas → 404 |
| AUTH-04 | M | Sesi absolut 30 hari, idle 14 hari, bisa dicabut | Sesi dicabut langsung 401 pada request berikutnya |
| AUTH-05 | M | Perubahan role tercatat di audit log | Setiap perubahan role punya baris aktor, target, waktu, alasan |
| AUTH-06 | S | CLI ops memakai bearer token terpisah dari sesi web | Token CLI tidak berlaku di route web |
| AUTH-07 | M | CSRF: perubahan state hanya dari origin sendiri | `Origin`/`Sec-Fetch-Site` asing → 403; cookie `SameSite=Lax` |
| AUTH-08 | M | Rate limit per route + per IP, memakai proxy tepercaya | Melebihi batas → 429 dengan `Retry-After`; IP asli terbaca di belakang proxy |
| AUTH-09 | M | `Idempotency-Key` disimpan bersama hash body | Reuse key dengan body berbeda → 409; key sama + body sama → hasil sama |
| AUTH-10 | S | Akun bisa dinonaktifkan dan dianonimkan tanpa menghapus riwayat rating | Nama/email/identitas Google dihapus; baris rating tetap utuh; audit mencatat aktor; login berikutnya ditolak |

### 4.2 Sesi & share link

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| SES-01 | M | `GET /sessions` tidak pernah memuat kode apa pun | Respons diuji: tidak ada `share_code` maupun `view_code` |
| SES-02 | M | Tautan baca (`view_code`) hanya untuk membaca | `GET` OK; `PATCH`/`PUT` dengan `view_code` → **401** (belum terautentikasi) |
| SES-03 | M | Hanya ada tautan baca (`view_code`), bisa dicabut dan dirotasi | Rotasi membuat kode lama 404; satu kode hidup per sesi |
| SES-04 | M | Menulis wajib sesi login; tautan tidak memberi hak tulis | `PATCH`/`PUT` tanpa sesi → 401; dengan `view_code` tetap 401 |
| SES-05 | M | Buat sesi/turnamen wajib `host` **di komunitas itu** | Anonim → 401; `member` → 403; `host` di komunitas lain → 404 |
| SES-06 | M | Lock tidak lagi memicu ingest poin | Lock → status `locked`; tidak ada baris `rating_events` baru |
| SES-07 | M | Ingest hanya untuk sumber `approved` | Sesi `locked` tanpa approval tidak menambah poin |
| SES-08 | S | Auto-lock tetap ada saat semua skor terisi | Skor terakhir → `locked`, tetap tanpa ingest implisit |

### 4.3 Live scoring

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| LIVE-01 | M | WebSocket memberi notifikasi perubahan, bukan state | Frame `session.changed` tanpa isi state; klien refetch |
| LIVE-02 | M | Catch-up selalu satu `GET` setelah reconnect | Putus → sambung → `ready` → refetch → state konsisten |
| LIVE-03 | M | Batas watcher per sesi/IP/proses | Melebihi batas → frame `full`, koneksi ditutup rapi |
| LIVE-04 | M | Mutasi granular idempoten & OCC | Replay request sama → hasil sama; `If-Match` basi → 412 |
| LIVE-05 | S | Heartbeat ping/pong | Koneksi mati terdeteksi < 60 s |

### 4.4 Pemain & peringkat

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| PLY-01 | M | Registrasi pemain wajib sesi login (`member` ke atas) | Anonim → 401; registrasi tidak memberi peran tambahan |
| PLY-02 | M | Merge/rename/delete/tier hanya `admin`+ | Role rendah → 403 |
| PLY-03 | M | Hapus pemain tidak menghapus riwayat pemain lain | Setelah delete, poin rekan/lawan tetap; `rebuild` menghasilkan angka sama |
| RNK-01 | M | Poin = window 12 minggu, best 10, base 250, pengali lawan 0.5–1.5 | Parity dengan v1 pada fixture; properti: monoton naik saat menang, invarian jumlah |
| RNK-02 | M | Papan top 200 per komunitas + filter tier | Halaman `/c/{slug}/rankings` menampilkan 200 baris komunitas itu saja |
| RNK-03 | S | Snapshot pergerakan (naik/turun) konsisten | Snapshot harian tidak drift terhadap perhitungan ulang |
| ACH-01 | M | Badge dihitung dari riwayat pertandingan; `earned_at` tidak turun | Menambah pertandingan tidak menghapus badge |
| ACH-02 | S | Backfill badge bisa dijalankan ulang, idempoten | Dua kali backfill → jumlah baris sama |

### 4.5 Turnamen

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| TRN-01 | M | Classic: 16 pair → 4 grup → knockout | Bracket dan standings parity dengan v1 |
| TRN-02 | M | Team: 6 tim × 6 pemain, 9 match + final | Skor per partai tersimpan; champion banner benar |
| TRN-03 | M | Skor turnamen bisa dikoreksi per match | `PATCH /tournaments/{id}/matches/{matchId}` mengubah satu match saja |
| TRN-04 | S | Delete turnamen membersihkan sumber rating | Delete → poin kembali ke kondisi sebelum turnamen |

### 4.6 Ekspor sosial

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| EXP-01 | M | Post 1080×1350 & story 1080×1920 untuk sesi dan turnamen | Render deterministik pada fixture; snapshot visual stabil |
| EXP-02 | C | Sponsor strip & logo tim | Ada di build yang sama dengan signature yang benar |

### 4.7 Operasi & observability

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| OPS-01 | M | `/healthz` = proses hidup, `/readyz` = DB + versi skema cocok | DB dimatikan → `/readyz` 503, `/healthz` 200 |
| OPS-02 | M | Metrics di listener internal, tidak publik | Port metrics tidak terjangkau dari internet |
| OPS-03 | M | Log terstruktur tanpa PII, file 0600 | Log tidak memuat email/nama/kode; permission diuji |
| OPS-04 | M | Deploy gagal → rollback otomatis & terverifikasi | Failure injection: build gagal, health gagal → `:prev` hidup |
| OPS-05 | M | Rilis tidak pernah hilang senyap | Deploy kedua saat deploy berjalan → antre atau gagal berisik, tidak `exit 0` |
| OPS-06 | M | Data sementara punya masa simpan dan dibersihkan otomatis | `auth.oauth_flows`, `idempotency_keys`, `outbox_events`, `session.links` kedaluwarsa, dan audit lama terhapus oleh janitor; jumlah baris terhapus terlihat di metrik |
| OPS-07 | S | Rilis berversi SemVer otomatis dari riwayat commit, dengan catatan rilis | `VERSION` satu-satunya sumber; tag `vX.Y.Z`; GitHub Release berisi catatan per kelompok; nomor versi hidup di `/version` |

### 4.8 Konfigurasi & parameter

Tidak ada angka atau aturan bisnis di dalam kode. Nilai seperti window poin, best-N,
band tier, ukuran turnamen, batas pagination, TTL, dan dimensi gambar dibaca dari DB.

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| CFG-01 | M | Setiap parameter punya key, tipe, nilai default, dan batas sah | Key tak dikenal → 400; nilai di luar batas → 400 |
| CFG-02 | M | Presedensi: override komunitas → default platform; **tidak ada default di kode** | Menghapus baris config wajib → server menolak start, bukan memakai angka tersembunyi |
| CFG-03 | M | Perubahan parameter berlaku tanpa restart dan tanpa deploy | Ubah `rank_window_weeks` → papan berubah pada request berikutnya |
| CFG-04 | M | Komunitas tidak bisa melewati batas aman platform | Nilai di atas plafon ditolak; plafon hanya bisa diubah platform owner |
| CFG-05 | M | Setiap perubahan parameter tercatat: aktor, nilai lama, nilai baru, waktu | Audit dapat ditelusuri per key |
| CFG-06 | M | Tidak ada literal angka bisnis di kode | `archcheck` menggagalkan build bila konstanta menduplikasi key config |
| CFG-07 | S | Parameter bisa diekspor/diimpor untuk bootstrap komunitas baru | Ekspor/​impor menghasilkan perilaku sama |
| CFG-08 | M | Konstanta teknis (status HTTP, SQL, kripto) dikecualikan lewat allowlist eksplisit | Allowlist ditinjau di code review, tidak tersembunyi |

## 5. Non-functional requirements

| Area | Target |
|------|--------|
| Latensi baca papan (p95, data 1 tahun) | < 150 ms |
| Latensi tulis skor (p95) | < 200 ms |
| Reconnect live | < 2 s sampai state konsisten |
| Memori proses (RSS, 50 watcher) | < 250 MB, tidak naik monoton |
| Availability deploy | Tanpa downtime; rollback < 60 s |
| Aksesibilitas web | WCAG 2.2 AA untuk alur inti; 0 violation pada halaman yang diuji |
| Mobile | Layar 360 px tanpa scroll horizontal; tap target ≥ 44 px |
| Keamanan | 0 P0/P1 terbuka; security suite lulus; **0 kebocoran lintas komunitas** |
| Test | Domain ≥ 90%, total ≥ 75% (ratchet) |
| Waktu check lokal | `./task check` ≤ 60 s |
| Bahasa antarmuka | Inggris; semua teks lewat kunci i18n, tanpa string keras di komponen |
| Backup | Dump harian, retensi 7 hari, snapshot sebelum impor; restore teruji < 30 menit |
| Retensi data | Sesi kedaluwarsa, flow OAuth, idempotency key, dan audit lama dibersihkan otomatis |

## 6. Perubahan UX yang harus disepakati

1. **Konteks komunitas**: semua halaman memakai `/c/{slug}/…`; ada pemilih komunitas
   untuk akun yang tergabung di lebih dari satu. Tautan publik tetap `/s/{code}` dan
   tidak menampilkan slug.
2. **Login**: tombol "Sign in with Google" menggantikan password admin. Menu admin
   muncul berdasarkan role **di komunitas aktif**, bukan role global.
3. **Share**: satu tautan "Lihat" (`view_code`) yang murni read-only. Tidak ada
   tautan tulis.
4. **Menulis skor**: semua penulis wajib login Google. Tidak ada kode tulis, tidak
   ada jalur anonim. Ini menghapus satu persona (scorer tamu) dengan sadar.
5. **Daftar sesi**: butuh login. Halaman publik hanya lewat tautan langsung.
6. **Papan peringkat**: tetap publik di dalam komunitas, tanpa login.
7. **Bahasa**: seluruh antarmuka berbahasa Inggris; teks diambil dari kunci i18n
   sehingga bahasa lain bisa ditambah tanpa mengubah komponen.
8. **Akun**: pengguna bisa meminta penonaktifan; nama dan identitas Google
   dianonimkan, riwayat poin tetap ada dan tetap dihitung. Tidak ada tombol
   "hapus semua data" yang akan merusak riwayat pemain lain.
9. **Arah desain**: mengikuti `docs/design-system.md` (tipografi IBM Plex, token
   warna `@theme` yang ada, kontras terhadap `--color-ground`). Halaman baru
   (login, pemilih komunitas, pengaturan) memakai token yang sama, bukan palet baru.

## 7. Metrik produk

- Waktu dari "buka tautan" ke "skor pertama tersimpan" < 15 s di 4G.
- 0 laporan poin tidak wajar setelah rilis.
- 0 insiden deploy yang butuh intervensi manual.
- Jumlah file yang harus disentuh untuk menambah satu aturan skor: **1**.

## 8. Di luar ruang lingkup

Multi-community sudah masuk ruang lingkup (lihat §4.0). Yang tetap di luar:
undangan email, notifikasi push, billing, aplikasi native, perubahan formula poin,
dan integrasi pihak ketiga selain Google. **Mengganti stack frontend (mis. ke Svelte)
juga di luar lingkup** — React 19 + Vite + Tailwind 4 dibekukan (O-17).

## 9. Keputusan pemilik (2026-11-03)

| Pertanyaan | Jawaban |
|---|---|
| Jendela P0 terbuka | diterima apa adanya, tanpa kontrol tambahan |
| Penonton menulis | tidak — `view_code` read-only |
| Host tanpa login | tidak — semua penulis login Google, `edit_code` dihapus |
| Impor data v1 | v2 rilis kosong, impor setelah stabil |
| Verifikasi RS256 | modul binding OpenSSL (ADR-009 diterima) |
| Peran `member` | R2 |
| Multi-komunitas | masuk repo ini; `community_id` + FK komposit; poin per komunitas; akun global dengan peran per komunitas |
| Topologi origin | FE `majadu.qouver.com` dan API `api.qouver.com` — satu site, cookie `SameSite=Lax` |
| Backup | Dump harian, retensi 7 hari, snapshot `bm` sebelum impor |
| Bahasa antarmuka | Inggris saja; kunci i18n disiapkan sejak R1 |
| Penghapusan akun | Nonaktifkan + anonimisasi, riwayat rating dipertahankan |

Tidak ada pertanyaan terbuka yang tersisa; perubahan berikutnya harus lewat
`contract-change.md` (T-016) bila menyentuh kontrak.
