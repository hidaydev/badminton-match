# Rilis

Runbook rilis v2: bagaimana sebuah versi dibuat, apa yang harus benar sebelum
dinyatakan selesai, dan bagaimana kembali ke rilis sebelumnya saat regresi
fungsional (bukan saat cutover — untuk itu `docs/ops/cutover.md`).

Status: alur build dan workflow ada di repo, tetapi **belum pernah dijalankan
ujung-ke-ujung di VPS**. Bagian yang belum terbukti disebut di §6; jangan
menganggapnya teruji.

## 1. Sumber kebenaran

| Artefak | Isi | Dipakai oleh |
|---|---|---|
| `VERSION` | versi yang sedang dikembangkan | `deploy-vps.sh` (gerbang deploy), `apps/api/src/app.nim` (`appVersion`) |
| `CHANGELOG.md` | bagian per versi dari Conventional Commits | rilis GitHub |
| tag `v<versi>` | SSH-signed, dibuat operator | `.github/workflows/release.yml` |
| image `ghcr.io/hidaydev/badminton-match:v<versi>` | satu build per tag | `deploy-vps.sh` (pull by digest) |
| digest `sha256:…` di body GitHub Release | mengikat tag ke image | `deploy-vps.sh`, `cutover.sh` |

`deploy-vps.sh` memutuskan deploy dari `VERSION`, bukan dari tag: commit yang
menaikkan `VERSION` adalah rilis, commit dokumentasi tidak. Karena itu tag harus
sudah terbit **dan** image-nya sudah ada sebelum `main` didorong.

## 2. Urutan rilis

1. `./task release` — dry run. Cetak bump, bagian changelog, dan perintah
   berikutnya; tidak menulis atau menandai apa pun.
2. `./task release --apply` — menulis `VERSION`, `CHANGELOG.md`, dan
   `.cache/release/v<versi>.md` (bahan tag). Hanya jalan bila working tree bersih
   dan tag terakhir cocok dengan `VERSION`.
3. Commit `chore(release): v<versi>`.
4. `git tag -s -F .cache/release/v<versi>.md v<versi>`.
5. **Push tag lebih dulu**, lalu `main`:

   ```sh
   git push origin refs/tags/v<versi>
   git push origin main
   ```

   Tag memicu `release.yml` (verify → image → publish). `main` memicu webhook
   deploy. Urutan sebaliknya membuat deploy berjalan sebelum image ada; skrip
   deploy akan gagal di langkah `resolve-digest`, bukan diam-diam memakai image
   lain.

   Catatan: `./task release` mencetak `git push origin main` sebelum perintah
   push tag. Yang benar adalah urutan di atas; keluaran alat itu belum
   diperbaiki.
6. Tunggu `release.yml` hijau dan catat digest dari body GitHub Release.
   `release.yml` tidak membuat atau memindahkan tag; tag selalu dari operator.

## 3. Apa yang dilakukan deploy

Setelah gate cutover (`MAJADU_PG_DSN` menunjuk `bm2`) dan cek versi, urutannya:

1. `git fetch origin main` + `git reset --hard origin/main`.
2. Resolve digest dari GitHub Release, `podman pull` digest itu.
3. **`dbtools migrate` + `dbtools verify`** dari image yang baru ditarik, memakai
   `MAJADU_OWNER_DSN`. Gagal di sini = rilis tidak dipasang, `:local`/`:prev`
   tidak disentuh, service yang lama tetap jalan.
4. Rotasi tag: `:local` → `:prev`, image baru → `:local`.
5. Sinkron unit systemd dan skrip operator dari repo.
6. Restart unit, tunggu `/readyz` (60 detik). Gagal → `:prev` dijadikan `:local`
   dan di-restart.
7. Jalankan `scripts/smoke.sh <health_url> <versi>`, yang mengunci `/version` ke
   versi yang baru ditarik. Gagal → rilis tidak dicatat, jadi push berikutnya
   mengulang versi yang sama.
8. Pastikan container benar-benar memakai image `:local`, lalu tulis
   `deploy/deployed-version` dan `deploy/last-release.json`
   (`version`, `commit`, `digest`, `schema`, `at`).

## 4. Exit criteria

Rilis belum selesai sampai keenamnya benar:

1. **Digest cocok.** `deploy/last-release.json` mencatat digest yang dipakai;
   nilainya harus sama dengan digest di body GitHub Release, dan
   `podman inspect --format '{{.Image}}' majadu-api` harus sama dengan
   `podman image inspect --format '{{.Id}}' localhost/majadu-api:local`
   (deploy sudah memeriksa pasangan terakhir ini di langkah `verify-image`).
2. **Versi cocok.** `curl -fsS http://127.0.0.1:8080/version` melaporkan versi
   **dan** commit yang dirilis (`-d:appVersion`/`-d:appCommit` dari
   `apps/api/Dockerfile`, `--build-arg` dari `release.yml`). Deploy sendiri
   sudah menjalankan `smoke.sh` yang memeriksa versinya; periksa manual hanya
   bila gate itu dilewati.
3. **24 jam tanpa restart loop.**
   `systemctl --user show majadu-api -p NRestarts` tetap 0 dan journal tidak
   memuat `StartLimit`/`Scheduled restart`.
4. **Tidak ada 5xx baru.** Counter ada di listener internal loopback
   (`MAJADU_METRICS_PORT`, tidak dipublikasikan); setelah 24 jam, baca
   `http_requests_total` dari dalam container dan log akses terstruktur unit
   (`"msg":"request"`) untuk route/status yang berubah.
5. **Smoke produksi lulus.**
   `ops/scripts/smoke.sh http://127.0.0.1:8080 <versi>` — `/version`,
   `/healthz`, `/readyz`, `/metrics` 404, share code asing 404, `/auth/me` 401.
   Deploy menjalankannya sendiri setelah `/readyz` hijau (langkah 7 §3); bila
   gate itu gagal, `deploy/deployed-version` tidak ditulis dan rilis dicoba lagi
   pada push berikutnya.
6. **`:v1-final` punya tanggal hapus dan digest yang diarsipkan.** Tag itu tidak
   pernah dihapus oleh deploy (`podman image prune -f` hanya membuang image tanpa
   tag); hapus manual setelah tanggal itu, dengan digest tercatat di catatan
   rilis.

Bila salah satu gagal, pakai §5, bukan menambal di server.

## 5. Rollback karena regresi fungsional (v2 → `:prev`)

Ini berbeda dari `ops/scripts/rollback.sh`, yang mengembalikan produksi ke **v1**
dan menghapus `cutover_state`. Untuk regresi di rilis v2, image yang benar adalah
`:prev`.

- **Otomatis** — dilakukan deploy sendiri bila `/readyz` gagal: `:prev` dijadikan
  `:local`, service di-restart, log mencatat `rolled back: :prev answers /readyz`.
- **Manual**, bila regresi baru terlihat setelah gate hijau:

  ```sh
  podman tag localhost/majadu-api:prev localhost/majadu-api:local
  systemctl --user restart majadu-api
  curl -fsS http://127.0.0.1:8080/version
  ```

  Lalu samakan `deploy/deployed-version` dengan versi yang sekarang menjawab.
  Tanpa itu, push berikutnya untuk versi yang gagal akan dianggap "sudah live"
  dan dilewati.

Skema tidak ikut di-rollback: `:prev` harus bisa melayani skema yang sudah
dimigrasi rilis baru. Aturannya di §6.

## 6. Migrasi: aturan expand/contract

Deploy menjalankan migrasi otomatis, jadi setiap rilis wajib memenuhi:

- **Hanya menambah** dalam satu rilis: tabel baru, kolom nullable atau
  `NOT NULL DEFAULT`, index baru. Jangan `rename`, `drop`, atau mengubah tipe
  kolom yang masih ditulis `:prev`.
- **Index `CONCURRENTLY` dikerjakan manual, di luar migrasi.** `dbtools migrate`
  menjalankan tiap berkas di dalam satu transaksi, dan PostgreSQL menolak
  `create index concurrently` di sana. Bangun index itu sebagai langkah operator
  sebelum deploy; migrasinya lalu hanya berisi `create index if not exists` yang
  menjadi no-op.
- **Berkas ber-header `-- contract` ditolak secara default.** Penghapusan baru
  boleh jalan lewat `dbtools migrate --allow-contract`, satu rilis setelah deploy
  yang berhenti memakai bentuk lama sudah menjadi `:prev`.
- **Seed idempoten** (`insert … on conflict do nothing`). `dbtools seed` tidak
  dipanggil deploy; seed baru hanya masuk lewat `cutover.sh` atau operator.
- **`/readyz` bukan pengganti `verify`.** Readiness hanya memeriksa keberadaan
  relasi (`to_regclass`); kolom atau seed yang hilang tetap lolos 200. Yang
  membuktikan skema adalah `dbtools verify` di langkah deploy.

`deploy/last-release.json` menyimpan `schema` (nama berkas migrasi terakhir), dan
log deploy mencatat `schema verified at <berkas>`. Saat rollback ke `:prev`,
baris log menyebut skema itu: `:prev` yang tidak kompatibel akan gagal di
readiness, bukan diam-diam menulis data salah.

## 7. Yang belum terbukti

- Tidak ada eksekusi nyata di VPS: `podman pull`/`run`, `systemctl --user`,
  Quadlet, dan Caddy tidak tersedia di mesin dev. Semua di atas dibuktikan hanya
  dengan `bash -n`, pembacaan kode, dan uji rehearsal T-063 — bukan produksi.
- `dbtools migrate` di dalam container memakai jaringan `qouver` dan role
  `bm2_owner`; kombinasi itu belum pernah dijalankan di VPS.
- Dua antrean rilis serentak belum diuji; `flock` menahan yang kedua sampai 900
  detik lalu menyerah.