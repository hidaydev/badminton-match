# Lingkungan RC

Instance RC adalah salinan produksi yang berdiri sendiri: service Podman
terpisah, database terpisah, dan FE di akun Vercel pemilik. Produksi tidak
disentuh sampai cutover.

Rencana lengkap dan alasan desainnya ada di `docs/plan/rc-environment.md`.

## 1. Yang ada di server

| Objek | Nilai |
|---|---|
| App dir | `/srv/qouver/apps/majadu-rc` |
| Checkout | `/srv/qouver/apps/majadu-rc/repo` |
| Unit | `majadu-rc-api.service` (Quadlet `majadu-rc-api.container`) |
| Container | `majadu-rc-api`, `127.0.0.1:8081 -> 8080` |
| Image | `localhost/majadu-rc-api:local` (+ `:prev`) |
| Database | `bm2_rc`, role `bm2_owner` / `bm2_app` |
| Env | `/srv/qouver/apps/majadu-rc/env/majadu-rc.env` (600, dir 700) |
| Caddy | `import /etc/caddy/site-rc.caddy` |
| URL publik | `https://api.qouver.com/majadu-rc/*` |
| Webhook | hook `majadu-monorepo` → `/srv/qouver/apps/majadu/scripts/deploy-dispatch.sh` |

`majadu2` (port 8093, DB `majadu`) adalah aplikasi lain dari repo lain. Jangan
disentuh dan jangan dipakai untuk RC ini.

## 2. Sekali saja: bootstrap

Prasyarat: env file sudah diisi (DSN, OIDC, share keys), dan `bm` sedang tidak
ditulis oleh proses lain.

```sh
# dari checkout di server
cd /srv/qouver/apps/majadu-rc/repo
git fetch origin release/2.0.0-rc.1
git reset --hard origin/release/2.0.0-rc.1

# Google subject pemilik, supaya layar admin bisa dipakai
MAJADU_OWNER_SUB=<sub> ./ops/scripts/bootstrap-rc.sh
```

Yang dilakukan skrip:

1. Build image dari branch RC (`APP_COMMIT` = commit yang diuji).
2. Buat role dan database `bm2_rc`, `dbtools migrate` + `seed`.
3. `pg_dump` database produksi (lewat container, karena host tidak punya
   `pg_dump`), restore ke `bm_restore_rc`.
4. `majadu-import etl` + `verify` ke `bm2_rc`.
5. Buat marker `deploy/seeded`, hapus database staging.
6. Jalankan `deploy-vps-rc.sh` untuk memasang unit dan menyalakan service.

Skrip menolak menimpa `bm2_rc` yang sudah berisi skema RC. Untuk membangun ulang
dengan data produksi terbaru: `./ops/scripts/bootstrap-rc.sh --force`.

## 3. Caddy (butuh sudo)

Sekali saja. Snippet harus bisa dibaca user `caddy`, jadi disalin ke `/etc/caddy`
(bukan dari app dir yang mode 700):

```sh
sudo install -o root -g root -m 644 ops/caddy/site-rc.caddy /etc/caddy/site-rc.caddy
```

Di dalam site block `api.qouver.com` di `/etc/caddy/Caddyfile`:

```
import /etc/caddy/site-rc.caddy
```

Lalu:

```sh
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl restart caddy
curl -fsS https://api.qouver.com/majadu-rc/healthz
```

`restart`, bukan `reload`: Caddyfile server ini memasang `admin off` (audit H-5),
jadi `caddy reload` tidak punya endpoint admin untuk dituju. Validasi dulu;
gagal validasi berarti tidak ada restart. Restart memutus semua site di server
selama sekitar satu detik.

Kalau isi `ops/caddy/site-rc.caddy` berubah, ulangi langkah `install` di atas —
deploy script tidak menulis ke `/etc/caddy`.

## 4. Deploy harian

Push ke `release/2.0.0-rc.1` → hook `majadu-monorepo` →
`deploy-dispatch.sh` → `deploy-vps-rc.sh`:

1. Dispatcher memilih target dari `ref`: `refs/heads/main` ke
   `deploy-vps.sh`, `refs/heads/release/2.0.0-rc.1` ke `deploy-vps-rc.sh`,
   ref lain `exit 0`.
2. Guard ref literal di script target; ref lain `exit 0`.
3. `flock` pada `/srv/qouver/apps/majadu-rc/.deploy.lock`.
4. `git fetch` + `reset --hard origin/release/2.0.0-rc.1`.
5. `:local` → `:prev`, `podman build` image baru.
6. `dbtools migrate` + `verify` terhadap `bm2_rc`.
7. Sinkron unit, restart `majadu-rc-api`, tunggu `/readyz` 60 detik.
8. `smoke.sh` + `/version` harus melaporkan commit yang baru dibangun.
9. Gagal di readiness → `:prev` jadi `:local`, restart, deploy dinyatakan gagal.
10. `image prune`; hanya `:local` dan `:prev` yang tersisa bertag.

### 4.1 Kenapa tidak ada webhook kedua

Remote `hidaydev/badminton-match` tidak menyediakan menu untuk menambah webhook,
jadi repo hanya punya satu hook: `majadu-monorepo` ke
`http://127.0.0.1:9000/hooks/majadu-monorepo`. Hook itu tidak memfilter ref;
setiap push masuk dan `deploy-dispatch.sh` yang memilih instance. Kedua script
target tetap memeriksa ref masing-masing, jadi kesalahan routing hanya bisa
melewatkan deploy, bukan menjalankan branch yang salah.

Konfigurasi daemon ada di `/srv/qouver/config/webhook.json` (milik `sachiel`,
mode 600); unit-nya user unit (`systemctl --user restart webhook`), bukan system
unit.

Manual, tanpa webhook:

```sh
/srv/qouver/apps/majadu-rc/scripts/deploy-vps-rc.sh badminton-match refs/heads/release/2.0.0-rc.1
```

Melihat keadaan terakhir:

```sh
cat /srv/qouver/apps/majadu-rc/deploy/last-release.json
journalctl --user -u majadu-rc-api -n 50 --no-pager
```

## 5. FE di Vercel

Project `majadu-rc` sudah dibuat di team `qouver` (akun Vercel pemilik) dan
setting berikut sudah diterapkan lewat API:

| Setting | Nilai |
|---|---|
| Root Directory | `apps/web` |
| Framework | Vite |
| Install Command | `pnpm install --frozen-lockfile` |
| Build Command | `pnpm run build` |
| Output Directory | `dist` |
| Node.js | 22.x |

Yang belum dan **tidak lagi wajib**: koneksi Git. Ada dua jalur, dan yang aktif
sekarang adalah yang pertama.

### 5.1 Deploy lewat token (aktif)

`deploy-vps-rc.sh` membangun SPA di VPS lalu mengirimnya ke project:

```sh
cd apps/web
vercel link --yes --scope qouver --project majadu-rc --token "$(cat env/vercel-token)"
vercel pull --yes --environment=production --token ...
vercel build --prod --token ...
vercel deploy --prebuilt --prod --yes --token ...
```

Token disimpan di `/srv/qouver/apps/majadu-rc/env/vercel-token` (mode 600) dan
hanya dipakai untuk project ini. Tanpa file itu, langkah web dilewati dan API
tetap deploy — jadi menambahkan atau mencabut token tidak mengubah jalur API.

Token yang terpasang berasal dari sesi CLI pemilik (`vca_…`). `vercel tokens
create` ditolak untuk login ini (`Cannot create tokens for this app`), jadi kalau
mau token terpisah: buat di dashboard Vercel → Account Settings → Tokens, lalu
timpa file di atas. Tidak perlu restart apa pun; deploy berikutnya memakai isi
file terbaru.

### 5.2 Deploy lewat Git (alternatif)

Kalau nanti ingin pipeline Vercel yang standar:

1. Pasang Vercel GitHub App untuk repo `hidaydev/badminton-match`
   (<https://github.com/apps/vercel/installations/new>). Akun yang memasang
   harus bisa melihat repo itu, dan akun Vercel `nferdazel` harus memakai
   identitas GitHub yang sama.
2. Di Vercel: Project `majadu-rc` → Settings → Git → Connect
   `hidaydev/badminton-match`, Production Branch `release/2.0.0-rc.1`.
3. Aktifkan "Include files outside Root Directory".
4. Hapus `env/vercel-token` kalau tidak ingin dua jalur berjalan bersamaan.

Deployment Protection harus off, kalau tidak callback OAuth dan tautan share
tertutup.

Branch RC membawa satu diff yang disengaja di `apps/web/vercel.json`:
`/api` diarahkan ke `https://api.qouver.com/majadu-rc/*`, bukan `/majadu/*`.

Google Cloud Console: tambahkan
`https://majadu-rc.vercel.app/api/auth/callback` ke Authorized redirect URIs.

Kalau yang terpasang malah `<project>-<team>.vercel.app`, ganti
`OIDC_REDIRECT_URI` di env RC dan URI di Google, lalu restart unit.

## 6. Setelah merge ke main

Begitu RC sudah divalidasi, cutover produksi memakai jalur yang sudah ada di
repo (`ops/scripts/cutover.sh`), bukan skrip RC ini:

1. Maintenance `/majadu/*`.
2. `cutover.sh` menjalankan dump `bm` → staging → import `bm2` → migrate →
   start unit produksi → pindah Caddy.
3. FE tetap `majadu.vercel.app`; `apps/web/vercel.json` di `main` kembali ke
   `/majadu/*` sehingga tidak ada perubahan domain.
4. `./task ranksnapshot` sekali setelah cutover.

Instance RC tetap hidup sebagai lingkungan uji sampai diputuskan untuk dimatikan.

## 7. Catatan yang ditemukan saat recon

- Host **tidak punya** `psql` dan `pg_dump`; `ops/scripts/backup.sh`,
  `restore.sh`, dan `cutover.sh` memanggil keduanya langsung. Untuk cutover
  produksi nanti, keduanya harus dipasang atau skripnya diubah memakai container.
  `bootstrap-rc.sh` sudah memakai container, jadi ia tidak terpengaruh.
- `apps/api/Dockerfile` di branch RC punya dua cacat yang membuat image tidak
  pernah bisa dibangun: base tag `nimlang/nim:2.4.0-bookworm` tidak ada di
  registry, dan `modules/` tidak pernah di-`COPY` padahal API mengimpornya.
  Keduanya sudah diperbaiki di branch RC. Artinya tag `v2.0.0` **harus** dibuat
  setelah merge, bukan dari `main` yang sekarang.
- Caddyfile server memakai `admin off` (audit H-5), jadi perubahan konfigurasi
  hanya bisa lewat `systemctl restart caddy`, bukan `reload`. Restart memutus
  semua site sekitar satu detik.
- Snippet Caddy harus berada di `/etc/caddy` karena user `caddy` tidak bisa
  menembus `/srv/qouver/apps/majadu-rc` (mode 700).
- `majadu` (port 8080, DB `bm`) adalah produksi v1 yang masih jalan.
  `majadu2` (port 8093, DB `majadu`) adalah aplikasi lain dari repo lain.
- Produksi memakai role `majadu_app`; role `bm2_*` belum ada di cluster.