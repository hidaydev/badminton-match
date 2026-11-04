# tools/rehearsal

Harness rehearsal cutover (T-063). Ini **bukan** bagian CI: ia butuh Podman,
sesi systemd user, Caddy, dan dua database rehearsal. Yang dijalankan adalah
`ops/scripts/cutover.sh` dan `rollback.sh` yang sama persis dengan produksi,
hanya saja menunjuk ke app dir, unit, site Caddy, dan database sandbox.

## Yang dibuktikan

- Urutan 12 langkah cutover berjalan pada `bm_staging` → `bm2_rehearsal`.
- Quadlet benar-benar dipakai: unit `majadu-rehearsal` dijalankan systemd.
- Caddy benar-benar dipakai: site sandbox di `:18081` mengimpor
  `active.caddy`, dan `/version` dijawab lewat Caddy, bukan hanya port app.
- `:v1-final` dipulihkan `rollback.sh` sampai `/healthz` v1 hijau.
- `--from restore-staging` benar-benar melanjutkan sisa urutan setelah
  `rollback.sh` menghapus `cutover_state`.
- Durasi per langkah, total, restore, jendela cutover, dan rollback ditulis ke
  `timings.json`.

## Yang tidak dibuktikan

- Caddyfile produksi `api.qouver.com` (site sandbox terpisah; `caddy validate`
  untuk file produksi tetap dilakukan sekali di server, lihat
  `ops/caddy/Caddyfile.api.qouver.com`).
- DNS, sertifikat, dan Cloudflare.
- Build image rilis: harness memakai digest rilis yang sudah terbit.
- Kenyamanan pengguna saat maintenance: itu keputusan jadwal, bukan hasil uji.

## Prasyarat (sekali, di VPS)

1. `bm_staging` berisi salinan database staging (dump + `restore.sh`).
2. Role `bm2_owner`, `bm2_app`, `bm2_etl` ada; `ops/db/roles.sql` membuatnya
   bila belum.
3. Salin template env:

   ```sh
   install -d -m 700 /srv/qouver/apps/majadu-rehearsal/env
   install -m 600 ops/env/rehearsal-v1.env.example \
     /srv/qouver/apps/majadu-rehearsal/env/v1.env
   install -m 600 ops/env/rehearsal-v2.env.example \
     /srv/qouver/apps/majadu-rehearsal/env/v2.env
   ```

   Isi nilai sebenarnya. Harness menolak file yang bukan mode 600 dan menolak
   DSN yang menunjuk `bm`, `bm2`, `bm2_dev`, atau `postgres`.
4. Image rilis `localhost/majadu-api:v1-final` ada (dari cutover produksi).
   Kalau belum ada, harness memakai `localhost/majadu-api:local` sebagai v1 —
   benar sebelum cutover pertama, salah sesudahnya.

## Menjalankan

```sh
MAJADU_REHEARSAL_ENV_DIR=/srv/qouver/apps/majadu-rehearsal/env \
  tools/rehearsal/rehearse.sh run --version v2.0.0 --dry-run   # lihat rencana

MAJADU_REHEARSAL_CONFIRM=yes \
MAJADU_REHEARSAL_ENV_DIR=/srv/qouver/apps/majadu-rehearsal/env \
  tools/rehearsal/rehearse.sh run --version v2.0.0             # jalankan
```

`--dry-run` hanya menyiapkan sandbox dan mencetak perintah; tidak menyentuh
systemd, Caddy, atau database.

`MAJADU_REHEARSAL_DIR` (default `/tmp/majadu-rehearsal`) adalah lokasi sandbox.
`MAJADU_REHEARSAL_ADMIN_DSN` (default `postgresql:///postgres`) dipakai untuk
membuat `bm2_rehearsal`.

Hasilnya `tools/rehearsal/timings.json`; commit file itu sesudah rehearsal.
`--no-from-proof` melewati pembuktian `--from`, tetapi gate lalu menolak
hasilnya.

## Gate

```sh
./task rehearsal check
```

Gate membaca `timings.json` saja (tidak butuh Podman), dan gagal bila:

- `status` bukan `passed`,
- `--from` tidak terbukti,
- hasilnya lebih tua dari 14 hari,
- total > 30 menit, restore > 15 menit, atau jendela cutover > 10 menit.

Jalankan gate ini sebelum D-day, bukan sesudah.

## Bersihkan

```sh
tools/rehearsal/rehearse.sh clean                    # unit, image, sandbox
tools/rehearsal/rehearse.sh clean --drop-databases   # + bm2_rehearsal
```

`bm_staging` tidak pernah dihapus harness; isinya dipakai ulang cutover
sesungguhnya.
