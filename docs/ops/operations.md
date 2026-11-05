# Operasi

Dokumen ini menjawab dua hal yang tidak boleh dicari saat insiden sedang terjadi:
siapa yang memegang akses, dan format catatan insidennya. Prosedur cutover punya
dokumen sendiri (`docs/ops/cutover.md`), begitu juga rilis
(`docs/ops/release.md`) dan login Google (`docs/ops/google-oauth.md`).

## 1. Pemegang akses

Instans ini dikelola satu orang (solo developer). Tabel ini adalah daftar
lengkap pemegang akses; menambah baris berarti menambah permukaan serangan.

| Aset | Dipakai untuk | Pemegang | Pengamanan |
|---|---|---|---|
| Akun Google `platform_owner` | Login ke aplikasi sebagai pemilik platform | Pemilik repo | MFA wajib, perangkat terpisah dari akun sosial |
| GitHub `hidaydev` | Repo, Actions, secret CI, advisory keamanan | Pemilik repo | MFA wajib (passkey/TOTP), tanpa login via password saja |
| VPS Qouver (`qouver.com`) | SSH ke host, `systemctl --user`, Podman rootless, `/srv/qouver/apps/majadu` | Pemilik repo | Kunci SSH saja, password login dimatikan, MFA di panel penyedia |
| GHCR (`ghcr.io`) | Registry image rilis | Pemilik repo | Token akses terbatas `read:packages`, disimpan di secret CI |
| Database `bm2` | Data produksi | Proses API (`bm2_app`), ETL (`bm2_etl`), pemilik skema (`bm2_owner`) | Password hanya di `/srv/qouver/apps/majadu/env/`, direktori mode `700` |

Aturan yang mengikat daftar ini:

- MFA wajib pada Google, GitHub, dan panel VPS. Tanpa MFA, satu password bocor
  berarti seluruh daftar di atas ikut bocor.
- Kredensial tidak pernah masuk repositori. Repo hanya memuat contoh:
  `ops/env/prod.env.example`.
- Akun yang tidak lagi dipakai dicabut di ketiga tempat: GitHub, panel VPS, dan
  `platform_owner` (lewat `./task opstoken`/CLI, bukan SQL manual).
- Peran database dipisah: aplikasi tidak punya hak menghapus `account.audit`,
  dan hanya `bm2_owner` yang menjalankan pembersih audit.

## 2. Insiden

Satu insiden, satu catatan, lima bidang. Tidak ada format lain; laporan panjang
tanpa lima bidang ini tidak bisa ditindaklanjuti.

```markdown
### Insiden YYYY-MM-DD — <judul singkat>

- **Deteksi**: bagaimana ketahuan (alert, laporan, temuan sendiri), jam, dan
  sinyal pertama yang muncul.
- **Dampak**: data atau fungsi apa yang terpengaruh, siapa yang terkena, berapa
  lama. Kalau belum diketahui, tulis "belum diketahui" dan perbarui.
- **Tindakan**: yang benar-benar dilakukan, berurutan, termasuk yang gagal.
- **Pencegahan**: perubahan yang mencegah pengulangan (kode, konfigurasi,
  proses), dengan tautan commit/PR.
- **Pemilik**: satu nama yang bertanggung jawab menutup tindak lanjut.
```

Aturan pengisian:

- **Dampak** menyebut data spesifik, bukan "sistem". Contoh yang benar:
  "riwayat skor 12 sesi komunitas X terbaca oleh tautan yang dicabut", bukan
  "kebocoran data".
- **Tindakan** mencatat waktu, bukan narasi. Kalau rollback dipakai, sebut
  image yang dipulihkan.
- **Pencegahan** wajib punya artefak: commit, perubahan konfigurasi, atau tes
  baru. "Akan lebih hati-hati" bukan pencegahan.
- Catatan disimpan di `.local/incidents/` (tidak masuk repo publik) dan
  diringkas di changelog rilis bila menyentuh pengguna.

## 3. Pemeriksaan rutin

| Kapan | Apa | Perintah |
|---|---|---|
| Setiap deploy | Kesehatan proses; migrasi dijalankan `deploy-vps.sh` sebelum restart | `curl -fsS http://127.0.0.1:8080/readyz` |
| Tiap 5 menit | `/readyz` dijaga `majadu-readyz.timer`; kegagalan memicu `majadu-alert@` | `systemctl --user list-timers majadu-readyz.timer` |
| Tiap jam | Log dirotasi `majadu-rotate-log.timer` (rename + hapus >14 hari) | `ls -l /srv/qouver/apps/majadu/logs` |
| Harian | Log deploy membesar tanpa rotasi | `ls -l /srv/qouver/apps/majadu/logs` |
| Bulanan | Migrasi dan seed masih cocok dengan skema | `./task ci` di mesin dev dengan `MAJADU_PG_DSN` |
| Tahunan | Daftar akses di atas masih akurat | tinjau manual, cabut yang tidak dipakai |

`deploy-vps.sh` menjalankan `dbtools migrate` lalu `dbtools verify` dari image
yang baru ditarik, memakai `MAJADU_OWNER_DSN`, sebelum unit di-restart.
Kegagalan di situ membatalkan deploy dan membiarkan rilis lama jalan; `:local`
dan `:prev` tidak disentuh.

`/readyz` sendiri hanya membalas `503` bila database tidak terjangkau, relasi
wajib belum ada (`to_regclass`), atau snapshot di `platform.cutover_state` tidak
cocok dengan `CUTOVER_SNAPSHOT_SHA256`. Kolom atau seed yang belum masuk tidak
terdeteksi di situ — yang membuktikan skema adalah `dbtools verify` di langkah
deploy. `503` berarti "jangan kirim trafik", bukan "coba lagi".

## 4. Yang belum ada

Jujur soal lubang lebih berguna daripada runbook yang mengandaikan alat yang
tidak ada:

- `ops/scripts/{cutover,rollback,backup,restore,smoke}.sh` sudah ada di repo,
  tetapi belum pernah dijalankan di VPS sungguhan. Rehearsal D-3 (T-063) yang
  membuktikannya; sebelum itu jangan menganggap jalur rollback teruji.
- Alert otomatis ada di level unit: `OnFailure=majadu-alert@%n.service` pada
  setiap unit, dan `deploy-vps.sh`, `cutover.sh`, serta `rollback.sh` memanggil
  template yang sama saat gagal. Tanpa `/srv/qouver/apps/majadu/env/alert.env`
  (mode 600) pesannya hanya masuk journal, tidak dikirim ke luar mesin.
  Retensi journal dan pengiriman journal ke luar host belum dikonfigurasi; itu
  langkah VPS, bukan berkas di repo ini.
- `readyz` dulu hanya probe; sekarang `majadu-readyz.timer` menembaknya tiap 5
  menit dan kegagalan menjadi alert. Metrik internal (T-062) tetap belum
  diekspos — `/ops/ping` hanya membuktikan token CLI hidup.
