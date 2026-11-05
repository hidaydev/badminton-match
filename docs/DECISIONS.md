# Architecture Decision Records

Keputusan arsitektur dan produk dicatat di sini supaya temuan yang sama tidak
diangkat ulang tiap audit. Dua jenis entri:

- **Diterapkan** — keputusan yang diambil dan sudah ada commit-nya (bentuk
  perbaikan, bukan sekadar "ini bukan bug").
- **Ditunda** — temuan yang sah tetapi sengaja tidak dikerjakan sekarang.

Setiap entri menyebut alasan dan apa yang akan membuka kembali keputusan itu.

Format: `## ADR-<nomor> · <judul>` — Tanggal, Status, Keputusan, Alasan,
Pembuka ulang.

---

## ADR-001 · Medali `rank_streak` mulai direkam v2, bukan direplay

**Tanggal:** 2026-11-05
**Temuan audit:** BE-10
**Status:** Diterapkan

**Keputusan:** v2 mulai menulis `rank_streak:<run>` dari riwayat peringkat yang
direkam sejak migration `0025`, tanpa mereplay masa lalu. Pemilik memilih
"sumber data ke depan", bukan rekonstruksi papan per tanggal sesi.

**Bentuk:** `rating.snapshots` mendapat kolom `rank` (nullable — baris lama
tidak punya peringkat, dan mengarang satu berarti mengklaim posisi yang tidak
pernah ditampilkan). `./task ranksnapshot` menulis kolom itu bersama poin.
`backfill` berjalan atas tanggal event komunitas; setiap tanggal tanpa baris
snapshot memutus run (peringkat tak terekam bukan bukti tetap di atas), dan run
terpanjang dengan peringkat ≤ 3 menjadi satu baris `rank_streak:<n>`.

**Alasan:** run hanya bisa diukur dari peringkat yang benar-benar dicatat;
merekonstruksi papan "as-of" tiap tanggal sesi berarti satu pass atas seluruh
riwayat dan tetap menebak window yang berlaku saat itu.

**Nilai yang sudah ada dipertahankan:** baris `rank_streak:*` hasil impor v1
memuat run yang diukur papan v1 dan tidak bisa dihitung ulang oleh v2. Karena
itu penulis mengambil nilai maksimum antara run baru dan baris yang sudah ada,
sehingga tidak ada medali yang turun dan tiap pemain tetap punya satu baris.
`tournament:<uuid>` tetap tidak disentuh rekonsiliasi (ADR-002).

**Pembuka ulang:** `ranksnapshot` berjalan sebagai timer produksi minimal 12
minggu, lalu run bisa dianggap lengkap dan aturan maksimum bisa diganti
rekonsiliasi penuh.

---

## ADR-002 · Rekonsiliasi medali mencabut, bukan menyimpan riwayat

**Tanggal:** 2026-11-05
**Temuan audit:** BE-31
**Status:** Diterapkan (`4024969`)

**Keputusan:** saat rating di-revert atau dibangun ulang, medali katalog yang
tidak lagi memenuhi ambang **dihapus**; medali yang kembali memenuhi ambang
dicatat dengan `earned_at` baru.

**Alasan:** medali adalah proyeksi dari data pertandingan, bukan catatan
independen. Kalau sesi yang menjadi dasarnya dicabut, mempertahankan medalinya
akan membuat papan penghargaan berbohong. Tanggal baru untuk medali yang diraih
ulang jujur: ia memang diraih lagi. Baris di luar katalog (`tournament:<uuid>`
impor dan `rank_streak`) tidak disentuh karena v2 tidak bisa menghitungnya
(ADR-001).

**Pembuka ulang:** ada kebutuhan menampilkan riwayat "pernah diraih" — saat itu
perlu tabel riwayat terpisah, bukan tabel `earned`.

---

## ADR-003 · `rating.levels` adalah data operator, bukan config

**Tanggal:** 2026-11-05
**Temuan audit:** BE-32
**Status:** Diterapkan (`4c10e85`)

**Keputusan:** tangga poin turnamen (`champion_points`, `round_ratios`) diisi
operator lewat `./task levels`; komunitas tanpa baris memakai rumus per-game.

**Alasan:** angka tangga adalah keputusan bisnis per komunitas, bukan konstanta
aplikasi. Menyemainya otomatis berarti mengarang angka. Bentuknya tabel (bukan
key registry) karena isinya JSON bertingkat dan berbeda per jenis turnamen.
Rumus per-game tetap ada supaya komunitas baru langsung punya poin tanpa
menunggu operator.

**Pembuka ulang:** tangga ingin diatur dari UI admin, bukan CLI — saat itu perlu
rute + perubahan kontrak.

---

## ADR-004 · Dua model rating (tier vs state) tidak disatukan

**Tanggal:** 2026-11-05
**Temuan audit:** BEP-10
**Status:** Ditunda

**Keputusan:** `player.tier` dan `rating_players` tetap berdampingan.

**Alasan:** menyatukan keduanya mengubah poin tersimpan untuk semua komunitas
dan membuat hasil impor v1 tidak bisa dibandingkan lagi. Keduanya menjawab
pertanyaan berbeda: tier adalah kelas yang dipakai untuk bagan, state adalah
akumulasi poin 12 minggu. Yang bisa diperbaiki tanpa mengubah angka sudah
diperbaiki (sumber tunggal untuk papan: `rating/read.nim`).

**Pembuka ulang:** ada migrasi yang memetakan tier ke state dengan persetujuan
pemilik data dan pengujian ulang seluruh riwayat.

---

## ADR-005 · Empty state + alur join request

**Tanggal:** 2026-11-05
**Temuan audit:** UX-10
**Status:** Diterapkan (`d95247a`)

**Keputusan:** akun tanpa komunitas mendapat satu aksi yang benar-benar
tersedia: pemilik platform diarahkan membuat komunitas, akun lain mengirim
permintaan bergabung (`POST /c/{slug}/join-requests`, selalu 202).

**Alasan:** petunjuk lama menyuruh "create a community" kepada akun yang tidak
punya hak itu. Balasan 202 yang seragam adalah perlindungan anti-enumerasi,
jadi layar hanya boleh menyatakan "terkirim", bukan "komunitas ditemukan".

**Pembuka ulang:** ada alur undangan berbasis tautan yang perlu ditampilkan di
layar yang sama.

---

## ADR-006 · Satu kamus i18n, satu locale

**Tanggal:** 2026-11-05
**Temuan audit:** UX-14
**Status:** Diterapkan (`e5421fc`)

**Keputusan:** `apps/web/src/i18n/en.ts` adalah satu-satunya kamus. Kamus kedua
(`src/legacy/i18n`) dihapus; pemanggil template memakai `t(key, vars)`.
`<html lang="en" dir="ltr">` statis.

**Alasan:** dua kamus berarti dua tempat untuk setiap penambahan teks dan satu
temuan audit yang berulang. Hanya bahasa Inggris yang aktif, jadi menerjemahkan
tanggal ke locale peramban akan membuat UI Inggris berisi tanggal berbahasa
lain; `formatLongDate` memusatkan keputusan itu di satu fungsi.

**Pembuka ulang:** bahasa kedua benar-benar dikerjakan — saat itu `en.ts`
menjadi `en.ts` + `id.ts` dan `t()` memilih kamus.

---

## ADR-007 · Metrik hidup di listener internal, bukan di port publik

**Tanggal:** 2026-11-05
**Temuan audit:** OPS-09
**Status:** Diterapkan

**Keputusan:** `/metrics` tetap tidak ada di port publik (`smoke.sh` menjaga
404). Registry counter permintaan di-increment di jalur respons tunggal dan
dirender oleh listener kedua yang hanya mengikat `127.0.0.1`, diaktifkan lewat
`MAJADU_METRICS_PORT` (kosong/0 = mati). Setiap respons juga menulis satu baris
log akses terstruktur (`method`, `route` template, `status`) lewat logger yang
sudah meredaksi nilai sensitif.

**Alasan:** counter yang tidak pernah di-increment/di-render bukan
observability. Listener loopback tidak menambah permukaan publik, dan label
memakai template route supaya kode share, slug, dan id tidak menjadi series;
path yang tak cocok digabung ke satu bucket agar pemindai tidak menumbuhkan
registry tanpa batas.

**Bukti di VPS** (image tidak memuat `curl`):

```bash
podman exec majadu-api bash -c \
  'exec 3<>/dev/tcp/127.0.0.1/9090; printf "GET /metrics HTTP/1.0\r\n\r\n" >&3; cat <&3'
```

**Pembuka ulang:** ada collector di VPS; saat itu cukup menambah publikasi port
atau scrape config, bukan mengubah kode.

---

## ADR-008 · Proyeksi papan membaca tanpa transaksi

**Tanggal:** 2026-11-05
**Temuan audit:** BEP-03
**Status:** Diterapkan

**Keputusan:** `projection.project` tidak lagi dibungkus `db.tx`. Setiap
pernyataan memakai `db.query`/`db.read`, yang meminjam satu koneksi lalu
mengembalikannya, dan agregasi berjalan setelah tidak ada koneksi yang dipegang.
Pool tetap menyisakan dua koneksi per proses (`apps/api/src/main.nim`) untuk
panggilan `Db` bersarang.

**Alasan:** dengan pool seukuran jumlah worker, satu papan yang menahan koneksi
selama seluruh agregasi mengurangi kapasitas untuk semua request lain. READ
COMMITTED memberi tiap pernyataan snapshot-nya sendiri, jadi transaksi luar tidak
menambah konsistensi yang berarti untuk laporan titik-waktu ini.

**Pembuka ulang:** papan butuh snapshot yang benar-benar seragam antar
pernyataan (mis. pagar terhadap rebuild bersamaan); saat itu pakai transaksi
`repeatable read` yang eksplisit, bukan `db.tx` biasa.

---

## ADR-009 · `breakdown` tetap dikirim untuk setiap baris papan

**Tanggal:** 2026-11-05
**Temuan audit:** BEP-07
**Status:** Ditunda

**Keputusan:** payload papan tidak diubah; `breakdown` tetap ada di setiap baris.

**Alasan:** `breakdown` adalah alasan angka terlihat masuk akal bagi pemain, dan
memindahkannya ke `?include=` mengubah kontrak publik yang sudah dipakai klien
lain. Biaya serialisasinya sudah terukur kecil setelah N+1 turnamen diperbaiki
(BEP-02). Optimasi yang mengubah bentuk respons harus datang bersama kebutuhan
yang nyata, bukan dari temuan hipotetis.

**Pembuka ulang:** ada klien yang mengeluh ukuran payload, atau papan melewati
batas waktu dengan `rank.board_limit` yang wajar.

---

## ADR-010 · Dua pemilik state sesi tidak disatukan sekarang

**Tanggal:** 2026-11-05
**Temuan audit:** FE-13
**Status:** Ditunda

**Keputusan:** state sesi tetap dimiliki Zustand (draft generator) dan query
cache (snapshot server).

**Alasan:** keduanya menyimpan hal yang berbeda: draft yang belum dipublikasikan
vs snapshot yang sudah ada di server. Menyatukannya adalah refactor lintas
routing dan puluhan komponen, bukan perbaikan bug; bug yang nyata (versi basi,
cache lintas komunitas) sudah diperbaiki di tempatnya.

**Pembuka ulang:** draft offline dan snapshot server perlu digabung untuk fitur
baru (mis. edit offline), atau muncul bug yang hanya bisa dijelaskan oleh dua
pemilik itu.

---

## ADR-011 · Beranda belum menampilkan sesi hari ini, peringkat, dan medali saya

**Tanggal:** 2026-11-05
**Temuan audit:** UX-03
**Status:** Ditunda

**Keputusan:** beranda tetap menampilkan pintasan dan sesi terakhir.

**Alasan:** "peringkat saya" dan "medali saya" membutuhkan tautan akun →
pemain. Klaim pemain ada, tetapi tidak wajib, dan akun tanpa klaim tidak punya
pemain untuk ditanyakan. Menampilkannya hanya untuk akun yang sudah mengklaim
akan membuat beranda berbeda bentuk antar pengguna tanpa aturan yang jelas.

**Pembuka ulang:** ada keputusan produk tentang beranda untuk akun tanpa klaim
(mis. meminta klaim dulu, atau memilih pemain default).