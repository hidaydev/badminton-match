# Community segregation — keputusan yang butuh alasan tertulis

## K-1 — RLS sebagai backstop database (S-3): ditunda ke siklus sendiri

**Pertanyaan.** Apakah RLS dipasang sekarang, sebagai jaring pengaman untuk
predikat `community_id` yang terlupa?

**Keputusan.** **Tidak di siklus RC ini.** Risiko praktisnya ditutup oleh S-2
(lint yang kini memindai `apps/` dan menutup tiga kelas bypass), S-4 (foreign-id
diuji per keluarga route), dan S-5 (kelas akses dispatch dibandingkan dengan
matrix). RLS tetap menjadi pekerjaan tersendiri, bukan dibatalkan.

**Mengapa tidak sekarang.** Tiga hal, semuanya bisa dibuktikan dari kode:

1. **Ada lookup yang sah sebelum komunitas diketahui.** `/s/{code}` membaca
   `session.links` untuk menemukan komunitasnya sendiri
   (`modules/share/store.nim:107-140`). Policy
   `community_id = current_setting('app.community_id')` akan menyembunyikan baris
   itu, sehingga link publik yang sedang dibagikan justru mati. RLS membutuhkan
   jalur privileged yang eksplisit untuk tabel ini, dan itu desain baru.
2. **Tidak semua akses lewat transaksi.** `db.query`/`queryOne`/`execUpdate`
   memakai `withConn` tanpa `BEGIN` (`shared/platform-lib/db/db.nim:343-357`),
   jadi `SET LOCAL` tidak cukup; nilai harus dipasang per koneksi yang dipinjam
   dari pool, dan di-reset agar tidak bocor ke pemakai berikutnya.
3. **Test hari ini berjalan sebagai owner.** RLS tidak berlaku bagi pemilik
   tabel tanpa `FORCE ROW LEVEL SECURITY`; suite di `bm2_test` memakai role
   owner, jadi policy tidak akan teruji. Membuktikannya butuh koneksi kedua
   sebagai `bm2_app` dan database dengan **dua** komunitas — RC sekarang hanya
   punya satu, sehingga semua query lintas-komunitas saat ini vacuous.

**Bentuk implementasi bila dikerjakan.**

- Migrasi baru: `enable row level security` + policy per tabel ber-`community_id`;
  `force` hanya setelah terbukti tidak memutus job platform.
- Context: satu threadvar per request (`scoped()` mengisinya), dipasang di
  `acquireConn` dengan `set_config('app.community_id', $1, false)` dan di-reset
  saat koneksi dikembalikan.
- Jalur privileged: `session.links`, `auth.flow`, `platform.community`,
  `platform.janitor`, `rating.ingest`, `achievement.backfill` memakai role
  `BYPASSRLS` atau policy khusus, masing-masing dengan alasan tertulis.
- Bukti: test yang berjalan sebagai `bm2_app` pada database dua komunitas,
  minimal untuk `session.sessions`, `player.players`, `rating.events`.

**Yang harus diputuskan owner.** Apakah RLS masuk sebelum rilis produksi
(menambah satu siklus kerja + perubahan plumbing koneksi), atau setelah
observabilitas dan dua-komunitas staging tersedia. Rekomendasi: setelahnya,
karena jaring pengaman yang tidak bisa diuji lebih berbahaya daripada tidak ada
jaring pengaman.

---

## K-2 — Ambiguitas nama: global vs konteks halaman

**Temuan.** `SessionPreviewPage` menghitung ambiguitas hanya dari peserta sesi
(`combineAmbiguous(new Set(), …)`), sedangkan `GlobalAmbiguousNames` dan
`GeneratePage` menggabungkan seluruh populasi. Akibatnya pemain yang sama bisa
tampil "Arya" di halaman sesi dan "Arya (i)" di layar lain.

**Keputusan.** Belum diubah. Perilaku per-sesi adalah yang diinginkan owner
(hemat ruang horizontal); yang perlu diputuskan adalah apakah layar lain harus
mengikuti aturan yang sama, atau tetap memakai populasi penuh agar dua pemain
ber-baseName sama tidak pernah tampil identik di daftar gabungan.

**Rekomendasi.** Pertahankan dua aturan dengan alasan eksplisit: halaman yang
hanya memuat peserta satu sesi memakai ambiguitas sesi; halaman yang mencampur
populasi (ranking, daftar pemain, riwayat) memakai populasi. Beri komentar di
`nameParser.ts` agar perbedaan itu tidak dianggap bug.