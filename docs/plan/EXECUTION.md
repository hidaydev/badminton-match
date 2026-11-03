# EXECUTION — cara memulai

Dokumen ini menjawab satu pertanyaan: **kalau besok mulai, langkah pertamanya apa.**
Rencana lengkap ada di `README.md`, `PRD.md`, `TECH-SPEC.md`, `BACKLOG.md`.

---

## 1. Prasyarat (diverifikasi 2026-11-03 di mesin ini)

| Alat | Status | Versi | Dipakai untuk |
|------|--------|-------|---------------|
| Nim | tersedia | 2.4.0 arm64 | seluruh backend |
| pnpm | tersedia | 11.25.0 | frontend |
| PostgreSQL | **berjalan** | 18.6 (Homebrew) | DB dev `bm2_dev` |
| psql | tersedia | 18.6 | inspeksi, reset |
| Go | tersedia | 1.27.3 | hanya untuk menjalankan v1 (parity capture) |
| Podman | **tidak terpasang** | — | opsional; jangan dijadikan default |
| `gh` CLI | tersedia | 2.103.3 | membuat GitHub Release dari tag (T-107) |
| Kunci SSH | tersedia | `~/.ssh/id_ed25519` | tanda tangan tag rilis (`gpg.format ssh`) |

Konsekuensi: T-007 memakai cluster PostgreSQL lokal, bukan container. Skrip `./task dev-db`
harus mendeteksi server lokal lebih dulu; container hanya fallback untuk mesin lain.

Cek cepat sebelum mulai:

```bash
nim --version
pnpm --version
psql -Atc "select version()" postgres
```

## 2. Urutan bootstrap (jalur kritis)

Tidak ada pekerjaan lain yang boleh dimulai sebelum dua jalur ini selesai:

```text
T-001 skeleton ── T-002 pin deps
              ├─ T-003 platform-lib ── T-004 db binder ── T-005 dbtools ── T-006a ... d
              ├─ T-008a/b OpenAPI ── T-009 contract-gen ── T-015 mock-api
              ├─ T-007 dev DB
              ├─ T-010 archcheck
              └─ T-011 CI
```

Target hari pertama:

1. `T-001` — `./task check` jalan di repo kosong (format, nim check, archcheck stub).
2. `T-002` — versi dependensi terkunci, `./task deps-check` gagal saat drift.
3. `T-003` + `T-004` paralel — logger/clock/ids dan pool/binder.
4. `T-007` — `bm2_dev` + template + reset < 5 s.

Setelah itu `T-005 → T-006a` dan `T-008a/b → T-009` boleh jalan bersamaan di dua agen
berbeda. Jangan menambah agen ketiga sebelum `T-006a` selesai.

## 3. Menyerahkan task ke subagent

Template yang dipakai orchestrator (salin apa adanya, isi bagian dalam kurung):

```text
Task: <T-xxx> — <judul>
Repo: /Users/sachiel/Projects/badminton-match
Owns (hanya boleh menulis di sini): <kolom Owns>
Baca dulu: docs/plan/TECH-SPEC.md §<bagian>, BACKLOG.md baris T-xxx
Acceptance (harus lulus): <kolom Acceptance>
Larangan:
- jangan menyentuh file di luar Owns
- jangan mengubah packages/contracts/openapi/{core,community}.yaml (hanya T-008a/b, digerbang T-016)
- jangan commit, jangan push
- jangan menambah dependensi di luar yang dipin T-002
Selesai bila: acceptance lulus + ./task check hijau + ./task verify <modul> hijau,
dan laporkan file yang berubah + bukti test.
```

Aturan tambahan untuk agen backend:

- Semua query wajib lewat binder (T-004); `dbQuote` di store = tolak.
- Semua query domain wajib punya `community_id`; tidak ada pengecualian.
- Semua angka bisnis dibaca dari registry config (T-096); literal = tolak.
- Komentar dan identifier bahasa Inggris; dokumen internal Indonesia.

## 4. Protokol merge (lokal)

1. Setiap agen bekerja di worktree sendiri (`git worktree add`).
2. Orchestrator memeriksa: file di luar `Owns` tidak berubah, `./task check` hijau.
3. Merge berurutan sesuai dependency; konflik di `api.yaml`, `task`, `config.nims`
   diselesaikan orchestrator, bukan agen.
4. Tidak ada push. Remote tidak disentuh sampai R4.

## 5. Definisi "R0 selesai"

- `./task check` ≤ 60 s dari commit bersih.
- `./task dev-db` membuat `bm2_dev` dari nol < 20 s; clone worker < 1 s.
- `dbtools verify` bersih pada `0001`–`0005`.
- `./task build` menghasilkan binary yang berjalan dan merespons `/healthz`.
- `./task contract-gen` menghasilkan 72 operasi dan `git diff --exit-code` bersih.
- `./task mock-api` melayani FE.
- Definisi CI lolos parse + skema (dan `actionlint` bila terpasang — belum ada di mesin ini);
  `./task ci` hijau lokal.

## 6. Operasional yang tidak boleh diimprovisasi

### 6.1 Google OAuth (sebelum T-021)

1. Buat project Google Cloud + OAuth consent screen (External, hanya scope
   `openid email profile`).
2. Credential: **Web application**. Authorized redirect URI **harus di host FE**,
   karena callback juga lewat proxy:
   `http://localhost:5173/api/auth/google/callback` (dev) dan
   `https://majadu.vercel.app/api/auth/google/callback` (prod).
   Mendaftarkannya di `api.qouver.com` membuat cookie flow dan callback berada di
   host berbeda → login selalu gagal.
3. Daftarkan juga alias staging tetap (`https://staging.majadu.vercel.app/api/auth/google/callback`)
   untuk menguji `Set-Cookie` lewat proxy sebelum cutover. Preview deployment acak
   tidak didaftarkan karena URL-nya berubah.
4. Simpan `GOOGLE_CLIENT_ID` dan `GOOGLE_CLIENT_SECRET` di
   `/srv/qouver/apps/<app>/env/` mode `600`; repo hanya memuat `.example`.
5. Rotasi: buat secret baru di console, deploy dengan secret baru, hapus yang lama
   setelah 24 jam. Kunci sesi dan `SHARE_CODE_KEYS` terpisah — menggantinya membuat
   semua sesi logout / semua tautan harus dienkripsi ulang, jadi lakukan bersamaan
   dengan deploy yang direncanakan.
6. Uji: login berhasil, `state` salah → 400, `nonce` salah → 400, akun tanpa
   `email_verified` → 403, `return_to` absolut → 400.

### 6.2 Backup & restore (sebelum impor apa pun)

- `ops/scripts/backup.sh` menjalankan `pg_dump -Fc` untuk `bm` dan `bm2`, retensi
  7 hari, mode `600`, dan memverifikasi hasilnya dengan `pg_restore --list`.
- Sebelum impor atau migrasi destruktif: dump tambahan + catat nama berkasnya.
- `ops/scripts/restore.sh <dump> <database>` menerima `bm`, `bm2`, `bm2_*`,
  `bm_restore_*`, dan **`bm_staging`**; menolak nama lain. Tanpa pengecualian
  `bm_staging`, guard ini memblokir satu-satunya langkah cutover yang
  membutuhkannya. `bm` produksi hanya bisa menjadi target bila dipanggil dengan
  `--i-know-this-overwrites-prod`.
- Latihan restore wajib di T-063; target < 30 menit dari dump terbaru.
- **Risiko yang diterima:** salinan berada di disk yang sama dengan database. Kalau
  VPS atau disknya hilang, backup ikut hilang. Ini keputusan biaya yang dicatat,
  bukan kelalaian.

### 6.3 Cutover instan (ETL sekali, saat v1 berhenti)

Rehearsal memakai `bm_staging` → `bm2_rehearsal` dan tidak menyentuh `bm` atau
`bm2`. Cutover sebenarnya dipicu **berkas penanda**, karena webhook hanya mengirim
repo + ref:

1. `touch /srv/qouver/apps/<app>/cutover.request` (isi: tag rilis).
2. Push `main` (atau jalankan `deploy-vps.sh --resume-cutover` bila sebelumnya
   gagal). Script mendeteksi penanda, melewati gate `apps/api/`, dan menulis
   `cutover.step` setiap langkah.
3. Langkah: `cutover.lock` → stop v1 (`systemctl --user stop`, bukan freeze) →
   `:v1-final` **hanya bila belum ada** → maintenance Caddy (non-GET 503) →
   `pg_dump` → restore `bm_staging` → siapkan `bm2` + migrasi + seed +
   `ownerseed --sub` → ETL satu transaksi → verifikasi → `cutover_state` →
   env + Caddy v2 → start → `/readyz` (skema + `CUTOVER_SNAPSHOT_SHA256`) →
   smoke → lepas maintenance → hapus `cutover.request` + `cutover.lock`.
   Bila `cutover_state` sudah terisi dan v2 sudah hidup, script menghapus penanda
   dan keluar `0` tanpa menyentuh layanan (anti-cutover-kedua).
4. Jika gagal di langkah mana pun: `rollback.sh` mengembalikan `:v1-final`, env
   `bm`, Caddy v1, dan start v1. `cutover.step` menunjukkan titik gagal; penanda
   **tidak** dihapus otomatis supaya kegagalan tidak hilang dari pandangan.
5. Reboot di tengah cutover: unit v2 memakai
   `ConditionPathExists=!/srv/qouver/apps/<app>/cutover.lock`, dan v1 sudah
   `systemctl --user stop`, sehingga ticker v1 tidak menulis ke `bm` selama dump.

Catatan:

- v1 **dihentikan**, bukan hanya dibekukan, supaya ticker ingest dan janitor tidak
  menulis selama dump.
- Komunitas default read-only sampai `platform_owner` mengangkat `admin`; ETL
  tidak membuat membership.
- Tautan `/s/{code}` lama tidak dipertahankan.
- Tab FE lama menerima `410 CLIENT_OUTDATED` + banner reload **hanya selama v2 hidup**; setelah rollback ke v1 pesan itu tidak ada, jadi runbook meminta reload paksa dan pengguna login ulang (sesi v2 tidak berlaku, data `bm2` setelah cutover hilang).

### 6.4 Rilis (setelah R4)

```bash
./task release auto --dry-run      # lihat versi + catatan, tidak menulis apa pun
./task release auto                # commit chore(release) + annotated tag lokal
./task release auto --push         # dorong commit + tag secara atomik
```

- Rilis pertama `2.0.0` (O-25); bump mengikuti tabel di TECH-SPEC §8.1.
- Tag wajib SSH-signed: `git config gpg.format ssh` +
  `user.signingkey ~/.ssh/id_ed25519.pub`; `allowed_signers` di-commit.
- Image dibangun **sekali** oleh workflow pada tag, didorong ke GHCR, dan digest-nya
  masuk GitHub Release. Deploy menarik digest itu, bukan rebuild.
- Urutan `--push`: tag dulu → tunggu Release + digest → baru `main`. Ini tidak
  atomik dengan sengaja; kalau workflow gagal, produksi tidak berubah.
- Jangan `--push` sebelum gate R4 lulus dan backup terbaru diverifikasi.

### 6.5 Higiene pra-push (T-108)

Repo publik, dan riwayat lokal memuat `docs/audits/` yang menjelaskan P0 v1.
Sebelum push pertama:

1. Perbaiki alat dulu: `git filter-repo` di mesin ini rusak
   (`bad interpreter` ke Python 3.14). Pasang ulang (`brew reinstall
   git-filter-repo` atau `pipx install git-filter-repo`) dan pastikan
   `git filter-repo --version` jalan.
2. Pasang hook: `git config core.hooksPath .githooks` (T-108), lalu pindahkan
   audit ke `.local/audits/` (sudah di-gitignore).
3. Tulis ulang riwayat agar path itu tidak pernah terbit:
   `git filter-repo --invert-paths --path docs/audits --force`.
   Langkah ini menghapus `origin`; tambahkan kembali setelah selesai.
4. Verifikasi: `git log --all --name-only | grep docs/audits` harus kosong.
5. Periksa ulang: tidak ada IP asli, kredensial, atau dump di riwayat.
6. Push pertama butuh `--force-with-lease` (riwayat berubah). Periksa ruleset
   GitHub dulu; kalau `non_fast_forward` aktif, longgarkan sementara untuk push
   pertama, lalu aktifkan kembali.
7. Baru `./task release --push`.

## 7. Jebakan yang sudah diketahui

| Jebakan | Tindakan |
|---|---|
| `nimble.lock` mematikan path global | jangan dibuat; pakai pin persis + `deps-check` |
| nimcache dipakai bersama antar-worktree, dan `check` vs build saling membatalkan | `./task` menyetel `--nimcache` per worktree **dua direktori** (`/check`, `/build`) (T-018) |
| Mummy default thread = core×10 dan `serverThreads` privat | `workerThreads` eksplisit dipakai untuk server **dan** pool |
| `db_connector` meng-escape, bukan bind, dan NULL jadi `""` | binder `PQexecParams` (T-004), termasuk NULL & operator jsonb `?` |
| migrasi dijalankan dua agen bersamaan | hanya `tools/dbtools`; satu pemilik migrasi per waktu |
| DB dev tercampur data uji antar agen | satu **database** per worker (`bm2_<agent>`) + guard prefiks `bm2_` |
| Mummy + ORC pernah SIGSEGV | `--mm:atomicArc` sejak hari pertama |
| Waktu tidak deterministik | `MAJADU_NOW` sejak test pertama; `DEFAULT now()` dilarang di tabel korpus (tidak bisa difake), kolom waktu lain diproyeksikan tetap |
| Mummy `destroy(true)` menutup socket sebelum drain | SIGTERM → `sleep(drain_ms)` → `close()`; handler 700 ms harus menerima respons utuh (T-001) |
| Mummy meng-gzip body > 860 byte tanpa `Vary` | replayer mengirim `Accept-Encoding: identity` |
| `-d:release` mencabut stack trace | build produksi memakai `--stackTrace:on` |
| macOS `dynlib` memilih LibreSSL Apple | soname eksplisit + `DYLD_FALLBACK_LIBRARY_PATH` keg `openssl@3` (T-084) |
| `libpq` keg-only di macOS | `DYLD_FALLBACK_LIBRARY_PATH` juga untuk `libpq` |
| Instance kosong tidak bisa boot | `T-103` bootstrap: platform_owner, komunitas pertama, seed config |
