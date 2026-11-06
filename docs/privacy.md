# Privasi

Aplikasi ini mencatat hasil pertandingan komunitas bulu tangkis. Dokumen ini
menyatakan data apa yang disimpan, atas dasar apa, berapa lama, dan apa yang
terjadi saat seseorang meminta akunnya ditutup. Ditulis untuk operator dan
pemain, bukan untuk auditor.

## 1. Dasar pemrosesan

- **Pelaksanaan kegiatan komunitas.** Nama pemain, pasangan, skor, dan jadwal
  dicatat karena tanpa itu komunitas tidak punya riwayat pertandingan dan
  peringkat. Pemain yang tidak ingin dicatat tidak perlu didaftarkan.
- **Persetujuan saat login.** Siapa yang boleh masuk ditentukan oleh login
  Google. Pemilik platform dan pengurus komunitas memakai akun itu untuk
  mengelola data; pemain memakainya untuk mengklaim baris pemain miliknya.
- Tidak ada profil iklan, tidak ada pelacakan lintas situs, tidak ada penjualan
  data ke pihak ketiga.

## 2. Data yang disimpan

| Data | Bentuk | Keterangan |
|---|---|---|
| Identitas Google | `google_sub` (id subjek) | Bukan email, bukan nama tampilan. Cukup untuk mengenali login yang sama. |
| Email | `email_hash` (SHA-256) | Email mentah tidak disimpan, termasuk pada undangan. |
| Nama tampilan | teks | Diambil dari akun Google saat login. |
| Keanggotaan | peran per komunitas (`admin`/`host`/`member`) | Satu pengguna bisa punya peran berbeda di komunitas berbeda. |
| Pemain | nama kanonik, alias, gender, tingkat | Dimiliki komunitas, bukan akun. Bisa ada tanpa akun. |
| Pertandingan | sesi, jadwal, skor, kehadiran, turnamen | Riwayat kegiatan komunitas. |
| Peringkat | event (jumlah entri), hitungan main/menang/kalah, snapshot | Turunan dari pertandingan; ledger poin per game tidak disimpan. |
| Audit | aksi, aktor, target, alasan | Tanpa email mentah, tanpa IP, tanpa kode tautan. |
| Sesi dan tautan | cookie sesi, hash kode tautan | Kode tautan disimpan sebagai hash + ciphertext, bukan teks biasa. |

Yang **tidak** disimpan: password (login lewat Google), alamat IP, user agent,
riwayat navigasi, dan email mentah.

Cookie yang dipakai hanya satu: cookie sesi `HttpOnly`. Tidak ada token di
JavaScript, tidak ada `localStorage`, tidak ada cookie pihak ketiga. Tautan
berbagi (`/s/<kode>`) bisa dibuka tanpa cookie dan hanya menampilkan isi sesi
yang dibagikan.

## 3. Retensi

| Data | Umur | Pengelola |
|---|---|---|
| Flow OAuth, kunci idempotensi, outbox, tiket WebSocket | `janitor.retention_days` (bawaan 30 hari) | `./task janitor`, peran aplikasi |
| Tautan yang dicabut | ikut janitor | `./task janitor` |
| Audit | `audit.retention_days` (bawaan 365 hari) | `./task audit-retention`, peran `bm2_owner` |
| Sesi login | menganggur `session.idle_days` (7 hari), mutlak `session.absolute_days` (30 hari) | aplikasi |
| Skor, turnamen, peringkat | tidak dihapus otomatis | komunitas |

Angka retensi adalah konfigurasi (`platform.config`), bukan konstanta kode, dan
bisa ditimpa per komunitas hanya ke arah yang lebih pendek atau lebih ketat.

## 4. Penutupan akun

`./task account anonymize --sub <google-sub> --actor <sub-aktor> [--reason <teks>]`
menjalankan satu transaksi:

1. Semua klaim milik akun ditutup dengan status `released` (riwayatnya tetap).
2. Baris pemain yang tertaut dilepas (`user_id` menjadi kosong), datanya tetap.
3. Keanggotaan komunitas (`community.membership`) milik akun dihapus di setiap
   komunitas yang pernah disentuh akun itu — termasuk komunitas yang hanya
   diikuti lewat membership, tanpa klaim atau pemain tertaut.
4. Sesi login dan tiket WebSocket dihapus.
5. `google_sub`, `email_hash`, dan `display_name` ditulis ulang menjadi identitas
   anonim, sehingga login dengan akun Google yang sama tidak lagi menemukan
   pengguna ini.

Keanggotaan dihapus, bukan dianonimkan, karena ia hanya tautan akun ke komunitas
dan tidak menyimpan riwayat pertandingan. Konsekuensi yang perlu diketahui
operator: bila akun yang ditutup adalah **satu-satunya admin** sebuah komunitas,
komunitas itu tertinggal tanpa admin dan harus diberi admin baru secara manual.

Yang **dipertahankan**: skor, turnamen, riwayat rating (event dan snapshot),
dan audit. Riwayat pertandingan milik pemain dan komunitas, bukan milik akun;
menghapusnya akan mengubah peringkat pemain lain. Audit tetap ada karena ia mencatat tindakan
administratif, bukan identitas.

Klaim yang sudah ditutup tidak bisa dibuka lagi dengan login yang sama, karena
identitas Google-nya sudah tidak terhubung.

## 5. Kebocoran data

Laporkan lewat GitHub private security advisory:

https://github.com/hidaydev/badminton-match/security/advisories/new

Jangan membuka issue publik, dan jangan menyertakan email, cookie sesi, atau
kode tautan di laporan. Untuk insiden yang sudah terjadi, catat dengan format
lima bidang di `docs/ops/operations.md` dan simpan di `.local/incidents/`.

## 6. Perubahan dokumen ini

Dokumen ini bagian dari kode: perubahan yang mengubah apa yang disimpan atau
berapa lama harus mengubah berkas ini di commit yang sama.
