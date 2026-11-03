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
| **Scorer tamu** | tanpa akun, memegang `edit_code` | Mengisi skor dari HP tanpa harus login, hanya untuk sesi yang dibagikan |
| **Penonton** | tanpa akun, `view_code` | Melihat skor dan jadwal berjalan tanpa bisa mengubah apa pun |
| **Pemain** | `member` (opsional) | Melihat poin, riwayat, badge; mempercayai bahwa poin tidak bisa dipalsukan |
| **Owner** | `owner` | Menjalankan operasi admin: merge pemain, rebuild poin, hapus turnamen |
| **Maintainer** | — | Mengubah satu aturan tanpa menyentuh tiga bahasa |

## 3. Rencana rilis

| Rilis | Isi | Gate keluar |
|-------|-----|-------------|
| **R0 — Fondasi** | Kontrak v2, skeleton Nim, local DB, parity harness, CI | `./task check` hijau; corpus parity bisa direkam; DB lokal naik < 20 s |
| **R1 — Auth & sesi** | OIDC Google, sesi/role, split `view_code`/`edit_code`, baca+tulis sesi, WebSocket live | Uji IDOR & eskalasi lulus; 3 sesi nyata berjalan di E2E |
| **R2 — Pemain & poin** | Player CRUD/merge, papan poin, achievement, ingest/revert/rebuild | Parity poin identik dengan v1 pada fixture yang sama |
| **R3 — Turnamen & ekspor** | Classic + team tournament, social export | Bracket & standings parity; export tervisualkan |
| **R4 — Cutover** | Deploy rehearsal, rollback drill, migrasi data | Failure injection lulus; owner menyatakan siap |

Aturan: **tidak ada rilis yang dimulai sebelum gate rilis sebelumnya lulus.**
Pekerjaan dalam satu rilis boleh paralel (lihat `BACKLOG.md`).

## 4. Functional requirements

Prioritas: **M** = must, **S** = should, **C** = could. Acceptance ditulis
sebagai kondisi yang bisa diuji otomatis.

### 4.1 Autentikasi & otorisasi

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| AUTH-01 | M | Login hanya lewat Google OIDC (Authorization Code + PKCE) | Login berhasil dengan akun Google; `state`/`nonce` salah ditolak 400 tanpa membuat sesi |
| AUTH-02 | M | Tidak ada token di JavaScript | Cookie sesi `HttpOnly`; tidak ada access token di localStorage/sessionStorage |
| AUTH-03 | M | Peran: `owner`, `admin`, `host`, `member` | Matriks route×role diuji; role rendah → 403, anonim → 401 |
| AUTH-04 | M | Sesi absolut 30 hari, idle 14 hari, bisa dicabut | Sesi dicabut langsung 401 pada request berikutnya |
| AUTH-05 | M | Perubahan role tercatat di audit log | Setiap perubahan role punya baris aktor, target, waktu, alasan |
| AUTH-06 | S | CLI ops memakai bearer token terpisah dari sesi web | Token CLI tidak berlaku di route web |
| AUTH-07 | M | CSRF: perubahan state hanya dari origin sendiri | `Origin`/`Sec-Fetch-Site` asing → 403; cookie `SameSite=Lax` |
| AUTH-08 | M | Rate limit per route + per IP, memakai proxy tepercaya | Melebihi batas → 429 dengan `Retry-After`; IP asli terbaca di belakang proxy |
| AUTH-09 | M | `Idempotency-Key` disimpan bersama hash body | Reuse key dengan body berbeda → 409; key sama + body sama → hasil sama |

### 4.2 Sesi & share link

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| SES-01 | M | `GET /sessions` tidak pernah memuat kode apa pun | Respons diuji: tidak ada field `share_code`/`edit_code`/`view_code` |
| SES-02 | M | Tautan baca (`view_code`) hanya untuk membaca | `GET` OK; semua `PATCH`/`PUT` dengan `view_code` → 403 |
| SES-03 | M | Tautan tulis (`edit_code`) terpisah, bisa dicabut/rotasi | Rotasi membuat kode lama 403; satu kode hidup per sesi |
| SES-04 | M | Kode dikirim via header, bukan query | `X-Edit-Code` diterima; kode di query string diabaikan dan dicatat |
| SES-05 | M | Buat sesi/turnamen wajib `host` | Anonim → 401; `member` → 403 |
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
| PLY-01 | M | Registrasi pemain boleh anonim, tapi tidak bisa menaikkan peran | Registrasi tidak menghasilkan sesi login |
| PLY-02 | M | Merge/rename/delete/tier hanya `admin`+ | Role rendah → 403 |
| PLY-03 | M | Hapus pemain tidak menghapus riwayat pemain lain | Setelah delete, poin rekan/lawan tetap; `rebuild` menghasilkan angka sama |
| RNK-01 | M | Poin = window 12 minggu, best 10, base 250, pengali lawan 0.5–1.5 | Parity dengan v1 pada fixture; properti: monoton naik saat menang, invarian jumlah |
| RNK-02 | M | Papan top 200 + filter tier | Halaman `/rankings` menampilkan 200 baris, filter bekerja |
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
| Keamanan | 0 P0/P1 terbuka; security suite lulus |
| Test | Domain ≥ 90%, total ≥ 75% (ratchet) |
| Waktu check lokal | `./task check` ≤ 60 s |

## 6. Perubahan UX yang harus disepakati

1. **Login**: tombol "Sign in with Google" menggantikan password admin. Menu admin
   muncul berdasarkan role, bukan setelah memasukkan token.
2. **Share**: dua tautan berbeda — "Lihat" (`view_code`) dan "Skor" (`edit_code`).
   Kode tulis dikirim lewat header, tidak tampil di address bar setelah dipakai.
3. **Host tanpa login**: tetap bisa scoring lewat `edit_code`. Jika `edit_code`
   hilang, host harus login Google untuk membuat tautan baru.
4. **Daftar sesi**: butuh login. Halaman publik hanya lewat tautan langsung.
5. **Papan peringkat**: tetap publik, tanpa login.

## 7. Metrik produk

- Waktu dari "buka tautan" ke "skor pertama tersimpan" < 15 s di 4G.
- 0 laporan poin tidak wajar setelah rilis.
- 0 insiden deploy yang butuh intervensi manual.
- Jumlah file yang harus disentuh untuk menambah satu aturan skor: **1**.

## 8. Di luar ruang lingkup

Multi-community, undangan email, notifikasi push, billing, aplikasi native,
perubahan formula poin, dan integrasi pihak ketiga selain Google.

## 9. Pertanyaan terbuka

1. Apakah `member` perlu ada di R1, atau cukup `owner/admin/host` dulu?
2. Apakah sesi lama (sebelum auth) harus tetap bisa diedit lewat `edit_code`
   tanpa login setelah cutover, atau dipaksa login sekali untuk migrasi?
3. Apakah papan peringkat perlu menampilkan pemain tanpa sesi (min_sessions=0)
   atau mempertahankan ambang 3?
4. Apakah ekspor sosial masuk R3 atau boleh digeser ke R4?
