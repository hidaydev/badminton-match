# Product Overview

## Tujuan

Majadu adalah aplikasi operasional badminton untuk satu atau banyak komunitas. Fokusnya:

- menjalankan sesi main (peserta, jadwal, skor, klasemen),
- mencatat hasil pertandingan dan turnamen,
- menghitung papan poin pemain,
- menyiapkan materi publikasi dari hasil sesi/turnamen.

Pertanyaan yang dijawab aplikasi:

- Siapa yang main hari ini dan siapa yang absen?
- Game apa saja yang dimainkan, di court mana, dan skornya berapa?
- Siapa yang memimpin klasemen sesi dan papan poin komunitas?
- Bagaimana hasil grup/bracket turnamen classic atau team?
- Gambar publikasi apa yang bisa diunduh dari hasil itu?

## Model komunitas & akses

- Satu instance melayani banyak komunitas. Setiap data operasional dimiliki satu
  `community_id`.
- Login memakai Google OIDC; tidak ada penulisan anonim. Cookie sesi `HttpOnly`.
- Role per komunitas: `member` (baca), `host` (tulis sesi/turnamen), `admin` (anggota,
  settings, rating, klaim). Platform owner hanya untuk manajemen platform.
- Tautan share `/s/{code}` bersifat baca-saja dan tidak memberi akses tulis.

## Area produk

### 1. Sesi

Data sesi: judul, tanggal, jam mulai, durasi slot, court, peserta, dan game.

- Jadwal disimpan relasional: satu baris `session.games` per `{round}-{court}`, dengan
  hingga dua pemain per sisi (`session.participants`).
- Skor satu game diubah lewat `PATCH …/games/{gameKey}`; skip game lewat
  `…/games/{gameKey}/skip`. Skor harus 0–99 dan tidak boleh seri.
- Absen ditandai per peserta; pemain absen tidak dihitung di klasemen dan tidak
  mendapat poin.
- Lock sesi mencatat siapa/waktu approve; unlock tersedia untuk host/admin.
- Klasemen sesi dihitung server: menang, selisih poin, poin untuk, lalu nama
  (`modules/session/standings.nim`).

**Status UI:** daftar dan detail sesi sudah ada, tetapi baru **baca-saja**. Membuat sesi,
mengisi jadwal, dan mengubah skor masih lewat API/klien lain.

### 2. Pemain

- Identitas utama `canonical_name`; pencarian/import memakai `alias` yang
  dinormalisasi dan unik per komunitas.
- Tier 8 level: `D`, `D+`, `C`, `C+`, `B`, `B+`, `A`, `A+`; boleh kosong.
- Gender `M`/`F`.
- Klaim pemain oleh akun: satu klaim `pending` per pemain, satu pemain ber-owner per
  akun per komunitas; keputusan klaim oleh admin.
- Merge memindahkan alias, klaim, delta rating, snapshot, achievement, pair, dan state
  rating ke pemain target, lalu menghapus sumber.
- Statistik pemain dan badge tersedia lewat API; halaman players belum dibangun.

### 3. Papan poin

- Poin dihitung dari `rating.deltas` dalam window bergulir **12 minggu**, mengambil
  **10 entri terbaik** per pemain; pemain dengan kurang dari **3 game** tidak masuk papan.
- Nilai game = `session_base × (0.5 + 0.5 × clamp(margin/score_target, -1, 1))`.
- Pengali kekuatan lawan = rasio rata-rata tier lawan terhadap populasi, dijepit
  `0.5–1.5`.
- Semua angka berasal dari config komunitas/platform (`rating.*`).
- Papan komunitas dibatasi `rank.board_limit` (200 baris) dan bisa difilter tier.
- Tidak ada rating absolut/Glicko dan tidak ada siklus musim.
- Detail pemain: peringkat, poin, main/menang/kalah, statistik, dan badge.
- Ingest hasil sesi/turnamen idempoten; sumber punya sign-off, dan revert menolak
  sumber yang sudah finalized.

### 4. Achievement

Badge dihitung backend dari riwayat pemain dan katalog di
`achievement.definitions`:

- kategori: `attendance`, `volume`, `opponent`, `tournament`, `tier`, `rank`, `social`;
- key menentukan metrik + ambang (mis. `sessions:10`, `games:25`, `rank:3`);
- badge tampil di `/c/{slug}/rankings/{playerId}`;
- key yang tidak ada di seed tidak bisa diterima (`achievement.earned` FK ke definisi).

### 5. Turnamen

**Classic:** 16 pasangan → 4 grup (A–D) → round-robin → knockout. Satu turnamen punya
32 match: 24 grup, 4 QF, 2 SF, 1 perebutan juara 3, 1 final. Draw dibuat di browser dari
seed, lalu disimpan lewat API.

**Team:** 6 tim × 6 kelas (`A+`…`C`), 9 match grup round-robin + 1 final, 3 partai per
match. Court per match bisa diedit; klasemen dan juara dihitung dari aturan domain yang
sama.

Admin bisa finalize source, ingest, revert rating, dan menghapus turnamen.

### 6. Ekspor sosial

- Sumber: klasemen sesi, grup/bracket/final classic, atau klasemen/final team.
- Dua varian: `post` (default 1080×1350) dan `story` (default 1080×1920).
- Ukuran dibaca dari config `export.*`, bukan hardcode.
- Render di canvas browser; hasil diunduh sebagai gambar.

### 7. Komunitas & operasi

- Undangan lewat email-hash + token; join request bisa dibuka/ditutup per komunitas.
- Settings komunitas adalah override dari registry platform; override hanya boleh
  mempersempit nilai platform.
- Audit append-only mencatat aksi privileged (aktor, target, hasil, before/after),
  dengan allowlist field agar kode share/email/IP tidak masuk bukti.
- Operasi CLI: `./task bootstrap`, `ingest`, `ranksnapshot`, `janitor`, `opstoken`,
  `audit-retention` (`task`).

## Realtime

Perubahan sesi disiarkan lewat WebSocket dengan ticket sekali pakai. Frame
`session.changed` hanya menandai bahwa state berubah (membawa `seq`), bukan mengirim
delta; klien harus membaca ulang sesi. Tidak ada SSE dan tidak ada replay event.
Frontend belum memakai WebSocket: halaman sesi memuat state saat dibuka.

## Arsitektur ringkas

- **Frontend** — React 19, Vite, Tailwind 4, React Router 7 (`apps/web`).
- **Backend** — Nim 2.4, Mummy HTTP + WebSocket, `db_connector` (`apps/api/src`).
- **Database** — PostgreSQL 18, database `bm2`, skema per domain (`db/migrations`).
- **Kontrak** — OpenAPI tulis tangan + codegen, 74 operasi
  (`packages/contracts/openapi`).

Detail: [`architecture.md`](architecture.md) · [`data-model.md`](data-model.md) ·
[`features-and-routes.md`](features-and-routes.md).
