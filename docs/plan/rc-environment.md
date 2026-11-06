# Lingkungan RC paralel dan cutover 2.0.0

Status: **rencana disetujui, artefak RC sudah dibuat, eksekusi bertahap.**
Tanggal: 2026-11-06.

Dokumen ini menjelaskan tiga hal: bagaimana RC dijalankan tanpa menyentuh
produksi, apa yang disiapkan di Vercel dan VPS, dan bagaimana merge ke `main`
memindahkan service + database tanpa mengganti domain FE.

---

## 1. Tujuan

| Push | FE | BE | DB |
|---|---|---|---|
| `main` (sekarang) | `majadu.vercel.app` (akun `hidaydev`) | `majadu-api` :8080 (v1) | `bm` |
| `release/2.0.0-rc.1` | `majadu-rc.vercel.app` (akun pemilik) | `majadu-rc-api` :8081 | `bm2_rc` |
| setelah merge | **tetap** `majadu.vercel.app` | unit produksi baru di :8080 | `bm2` |

Yang tidak berubah: domain FE produksi dan path `/majadu/*` di
`api.qouver.com`.

---

## 2. Keadaan server (recon 6 Nov 2026)

| Objek | Kenyataan |
|---|---|
| `majadu` | v1 produksi, image `localhost/majadu-api:local`, `127.0.0.1:8080`, DB `bm`, role `majadu_app` |
| `majadu2` | aplikasi **lain** dari repo `nferdazel/majadu`, port 8093, DB `majadu`, role `majadu2_app` |
| Postgres | container `qouver-postgres`, superuser `qouver`, DB: `bm`, `majadu`, `kran`, `sds`, `fond`, `qouver` |
| `bm2` | **belum ada** |
| Host | 2 vCPU, 7.4 GB RAM, 54 GB disk kosong, podman 5.8.2 |
| `psql` / `pg_dump` | **tidak terpasang di host** |
| sudo | butuh password (tidak ada NOPASSWD) |

Dua konsekuensi yang mengikat:

1. `backup.sh`, `restore.sh`, dan `cutover.sh` memanggil `pg_dump`/`psql`
   langsung. Di host ini ketiganya akan gagal. Skrip RC memakai container;
   cutover produksi nanti perlu `psql`+`pg_dump` dipasang atau skripnya diubah.
2. `majadu2` bukan target dan tidak boleh disentuh. Semua nama RC memakai
   `majadu-rc-*` supaya tidak bertabrakan.

Konsekuensi ketiga dari kode: satu database tidak boleh dilayani dua versi kode.
`session.game_results` menurunkan hasil dari `session.game_sets`, sementara kode
lama hanya menulis `session.games.score_a/score_b` dan kode baru tidak lagi
menulis kedua kolom itu. Karena itu pindah DB adalah syarat rollback, bukan
kemewahan.

---

## 3. Topologi RC

| | Produksi | RC |
|---|---|---|
| FE | `majadu.vercel.app` | `majadu-rc.vercel.app` |
| Rewrite FE | `/api/*` → `api.qouver.com/majadu/*` | `/api/*` → `api.qouver.com/majadu-rc/*` |
| Caddy | `handle /majadu/*` → `:8080` | `handle /majadu-rc/*` → `:8081` |
| Unit | `majadu-api` | `majadu-rc-api` |
| App dir | `/srv/qouver/apps/majadu` | `/srv/qouver/apps/majadu-rc` |
| DB | `bm` | `bm2_rc` |
| Deploy | webhook `main` → `deploy-vps.sh` (digest GHCR) | webhook RC → `deploy-vps-rc.sh` (build di VPS) |
| OIDC redirect | `https://majadu.vercel.app/api/auth/callback` | `https://majadu-rc.vercel.app/api/auth/callback` |

Tidak ada DNS baru, Postgres baru, atau akun Vercel baru selain project-nya.

---

## 4. FE: project Vercel RC

Project baru di akun pemilik, **Git-connected** ke `hidaydev/badminton-match`,
supaya "push branch → deploy" berjalan tanpa langkah manual.

| Setting | Nilai |
|---|---|
| Project name | `majadu-rc` |
| Production branch | `release/2.0.0-rc.1` |
| Root Directory | `apps/web` |
| Include files outside Root Directory | **on** (monorepo pnpm) |
| Framework preset | Vite |
| Install command | `pnpm install --frozen-lockfile` |
| Build command | `pnpm run build` |
| Output directory | `dist` |
| Node.js version | 22 |
| Environment variables | tidak ada; `VITE_API_BASE` dibiarkan kosong |
| Deployment Protection | **off** |

Prasyarat: branch RC ada di GitHub, akun Vercel bisa memasang GitHub App di repo
`hidaydev`, dan URI callback RC didaftarkan di Google Cloud Console.

### 4.1 Satu-satunya diff khusus RC

`apps/web/vercel.json` di branch RC:

```diff
-{ "source": "/api/:path*", "destination": "https://api.qouver.com/majadu/:path*" },
+{ "source": "/api/:path*", "destination": "https://api.qouver.com/majadu-rc/:path*" },
```

`Content-Security-Policy` tidak berubah karena origin tetap `api.qouver.com`.
Baris ini wajib dikembalikan ke `majadu` sebelum merge. Jaring pengamannya:
setelah cutover, `/majadu-rc/*` tetap menunjuk service yang sama, jadi lupa
revert tidak memutus produksi.

---

## 5. BE: instance RC di VPS

Artefak yang sudah ada di branch RC:

| Berkas | Isi |
|---|---|
| `ops/env/rc.env.example` | template env RC (DSN `bm2_rc`, OIDC domain RC) |
| `ops/systemd/majadu-rc-api.container` | port `127.0.0.1:8081`, image `localhost/majadu-rc-api:local` |
| `ops/scripts/deploy-vps-rc.sh` | deploy per push ke branch RC |
| `ops/scripts/bootstrap-rc.sh` | sekali jalan: DB + salinan data + start |
| `ops/scripts/deploy-dispatch.sh` | router ref untuk satu webhook GitHub |
| `ops/caddy/site-rc.caddy` | handler `/majadu-rc/*` → `:8081` |

### 5.1 `deploy-vps-rc.sh`

- Ref guard fail-closed dan literal:
  `if [ "$REF" != "refs/heads/release/2.0.0-rc.1" ]; then exit 0; fi`.
- `flock` sendiri (`/srv/qouver/apps/majadu-rc/.deploy.lock`), tidak berbagi lock
  produksi.
- `git fetch` + `reset --hard origin/release/2.0.0-rc.1`.
- **Build di VPS**: `podman build` dari checkout, rotasi `:local` → `:prev`.
  Tidak ada tag SHA, tidak ada GHCR, tidak ada tag git.
- `dbtools migrate` + `verify` terhadap `bm2_rc`; `seed` sekali (marker).
- Sinkron unit, restart, tunggu `/readyz` 60 detik, `smoke.sh`, lalu
  `/version` harus melaporkan commit yang baru dibangun.
- Gagal readiness → `:prev` jadi `:local`; deploy dinyatakan gagal.
- Catat `version`, `commit`, `schema`, `branch`, `at` di `deploy/last-release.json`.

Alasan build di VPS: RC deploy tiap push, sedangkan jalur rilis ada di balik tag
bertanda tangan + `VERSION`. Produksi tetap memakai jalur digest GHCR.

### 5.2 `bootstrap-rc.sh`

Sekali jalan, dan tidak menyentuh produksi:

1. Build image dari branch RC.
2. Buat role `bm2_rc_owner`/`bm2_rc_app` + database `bm2_rc`, migrate, seed.
3. `pg_dump` `bm` lewat container → restore `bm_restore_rc`.
4. `majadu-import etl` + `verify` ke `bm2_rc`.
5. Hapus database staging, jalankan `deploy-vps-rc.sh`.

Menolak menimpa `bm2_rc` yang sudah berskema RC; `--force` untuk rebuild.

---

## 6. Urutan cutover saat merge

Deploy kode otomatis; pindah data manual satu perintah. Alasannya: dump/restore
harus terjadi saat tidak ada penulis, dan kegagalan di tengahnya harus berhenti
dengan manusia di depan layar.

1. **Bekukan `main`** selama jendela cutover.
2. **Maintenance** `/majadu/*` (`site-maintenance.caddy`); service v1 tetap hidup.
3. **Salin data**: dump `bm` → restore `bm_staging` → `majadu-import` ke `bm2`
   → `dbtools migrate` + `verify` (ini isi `cutover.sh`).
4. **Ganti env produksi** ke DSN `bm2` dan `OIDC_REDIRECT_URI`
   `https://majadu.vercel.app/api/auth/callback`.
5. **Pindahkan trafik**: `/majadu/*` → unit produksi baru.
6. **Smoke**: `/readyz`, `/version`, login Google, satu sesi baru, satu skor,
   satu tautan share, papan peringkat.
7. **Matikan v1**, jangan hapus: unit, image `:v1-final`, dan DB `bm` tetap ada.
8. **Merge** `release/2.0.0-rc.1` → `main`, push. Webhook produksi kini
   men-deploy kode yang sama.
9. **Rilis**: `VERSION` = `2.0.0`, tag `v2.0.0`, tunggu `release.yml`, lalu
   `./task ranksnapshot` sekali.

`cutover.sh` sudah menangani langkah 2–7 dan `rollback.sh` mengembalikan v1.
Yang perlu diperbaiki sebelum dipakai: host belum punya `psql`/`pg_dump`.

---

## 7. Rollback

| Titik gagal | Tindakan |
|---|---|
| Smoke gagal setelah Caddy dipindah | Kembalikan `/majadu/*` ke upstream v1, reload; v1 masih hidup dan `bm` tidak disentuh |
| Data `bm2` rusak | Hapus `bm2`, ulangi dari dump; `bm` tidak pernah ditulis |
| Setelah v1 dimatikan | `systemctl --user enable --now majadu-api` + Caddy ke v1; data `bm2` setelah cutover hilang, jadi ini keputusan sadar |
| RC rusak | `deploy-vps-rc.sh` sudah otomatis kembali ke `:prev`; kalau perlu, jalankan `bootstrap-rc.sh --force` |

---

## 8. Risiko

1. **Akses GitHub di Vercel.** Repo milik `hidaydev`; akun Vercel pemilik harus
   bisa memasang GitHub App. Alternatif: deploy dari GitHub Actions dengan
   `VERCEL_TOKEN`.
2. **Satu redirect URI per instance.** Login RC hanya jalan setelah URI RC
   didaftarkan di Google. Jangan daftarkan domain preview acak.
3. **Host tanpa `psql`/`pg_dump`.** Menghalangi `cutover.sh` apa adanya.
4. **Beban VPS.** Build Nim untuk setiap push RC memakai 2 vCPU. Kalau terlalu
   berat, pindahkan build ke GitHub Actions dengan tag `rc` yang ditimpa.
5. **`pnpm check:tailwind` merah** karena dua kelas lama; CI branch RC merah
   sampai diperbaiki atau pemeriksanya dilonggarkan.
6. **`main` belum punya `VERSION`.** Muncul setelah merge; tag rilis tetap wajib
   sebelum push `main` menurut `docs/ops/release.md`.

---

## 9. Keputusan

| Pertanyaan | Jawaban |
|---|---|
| Domain RC | `majadu-rc.vercel.app` |
| Isi awal `bm2_rc` | salinan produksi lewat importer |
| Cutover | satu perintah manual, bukan otomatis dari webhook |
| Pelaksana langkah VPS | pemilik, lewat SSH dari mesin ini |
| Push branch RC | setelah artefak ops siap |
| Nama DB/service RC | `bm2_rc`, `majadu-rc-api`, path `/majadu-rc` |