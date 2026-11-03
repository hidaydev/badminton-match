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
              ├─ T-008 OpenAPI ── T-009 contract-gen ── T-015 mock-api
              ├─ T-007 dev DB
              ├─ T-010 archcheck
              └─ T-011 CI
```

Target hari pertama:

1. `T-001` — `./task check` jalan di repo kosong (format, nim check, archcheck stub).
2. `T-002` — versi dependensi terkunci, `./task deps-check` gagal saat drift.
3. `T-003` + `T-004` paralel — logger/clock/ids dan pool/binder.
4. `T-007` — `bm2_dev` + template + reset < 5 s.

Setelah itu `T-005 → T-006a` dan `T-008 → T-009` boleh jalan bersamaan di dua agen
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
- `./task contract-gen` menghasilkan 60 operasi dan `git diff --exit-code` bersih.
- `./task mock-api` melayani FE.
- Definisi CI lolos parse + skema (dan `actionlint` bila terpasang — belum ada di mesin ini);
  `./task ci` hijau lokal.

## 6. Operasional yang tidak boleh diimprovisasi

### 6.1 Google OAuth (sebelum T-021)

1. Buat project Google Cloud + OAuth consent screen (External, hanya scope
   `openid email profile`).
2. Credential: **Web application**. Authorized redirect URI:
   `http://localhost:8080/auth/google/callback` (dev) dan
   `https://api.qouver.com/auth/google/callback` (prod). Tidak ada origin JS.
3. Simpan `GOOGLE_CLIENT_ID` dan `GOOGLE_CLIENT_SECRET` di
   `/srv/qouver/apps/<app>/env/` mode `600`; repo hanya memuat `.example`.
4. Rotasi: buat secret baru di console, deploy dengan secret baru, hapus yang lama
   setelah 24 jam. Kunci sesi/cookie terpisah — menggantinya berarti semua user
   logout, jadi lakukan bersamaan dengan deploy yang direncanakan.
5. Uji: login berhasil, `state` salah → 400, `nonce` salah → 400, akun tanpa
   `email_verified` → 403.

### 6.2 Backup & restore (sebelum impor apa pun)

- `ops/scripts/backup.sh` menjalankan `pg_dump -Fc` untuk `bm` dan `bm2`, retensi
  7 hari, mode `600`, dan memverifikasi hasilnya dengan `pg_restore --list`.
- Sebelum impor atau migrasi destruktif: dump tambahan + catat nama berkasnya.
- `ops/scripts/restore.sh <dump> <database>` hanya menerima nama database berawalan
  `bm2_` atau `bm_restore_`; tidak pernah menimpa `bm` produksi.
- Latihan restore wajib di T-063; target < 30 menit dari dump terbaru.

### 6.3 Cutover instan (pra-impor, lalu satu push)

Tidak ada masa berdampingan. Urutannya:

0. **Siapkan `bm2` di VPS** (sekali saja): database `bm2`, role `bm2_app` dengan
   password dari env, lalu `dbtools migrate`.
1. **Snapshot** `bm` (`ops/scripts/backup.sh bm`) dan verifikasi dump bisa dibaca.
2. **Seed & bootstrap**: `dbtools seed` (L1 config) lalu `tools/ownerseed` —
   platform_owner pertama + komunitas default. Tanpa ini v2 menolak start dan ETL
   tidak punya `community_id` tujuan.
3. **Pra-impor** `bm` → `bm2` (`tools/import/etl`), lalu rekonsiliasi (`verify`).
   `bm` hanya dibaca; ETL boleh diulang dari snapshot baru.
4. **Uji baca** pada `bm2`: jumlah pemain, jumlah sesi, papan peringkat komunitas
   default, satu sesi acak. Gagal di sini → jangan push.
5. **Push ke `main`** → build + restart v2. `/readyz` hijau, smoke lulus.
6. **Verifikasi pasca-cutover**: login Google, buka `/c/{slug}/rankings`, buat satu
   sesi, simpan satu skor, buka satu tautan `/s/{code}` baru.
7. **Rollback** bila langkah 6 gagal: `systemctl --user restart` dengan image `:prev`
   (v1). `bm` utuh; data `bm2` setelah cutover dibuang. Rollback hanya mungkin
   selama image v1 masih ada.

Catatan penting:

- Cookie sesi sampai ke API lewat **proxy `/api/*` di Vercel**; jangan mengarahkan
  FE langsung ke `api.qouver.com` untuk HTTP, atau cookie menjadi pihak ketiga.
- WebSocket memakai `wss://api.qouver.com/...?ticket=`, bukan cookie.
- Baris yang ditulis ke v1 antara langkah 3 dan 5 tidak ikut terimpor; jalankan
  langkah 3 sedekat mungkin dengan 5 dan catat waktunya di runbook.
- Tautan `/s/{code}` lama tidak dipertahankan; host menerbitkan kode baru.

### 6.4 Rilis (setelah R4)

```bash
./task release auto --dry-run      # lihat versi + catatan, tidak menulis apa pun
./task release auto                # commit chore(release) + annotated tag lokal
./task release auto --push         # dorong commit ke main + tag (memicu deploy)
```

- Rilis pertama adalah `2.0.0` (O-25); bump berikutnya mengikuti tabel di TECH-SPEC §8.1.
- Tag wajib SSH-signed: `git config gpg.format ssh` + `user.signingkey ~/.ssh/id_ed25519.pub`.
  Workflow menolak tag tanpa tanda tangan valid.
- Rilis kandidat: `./task release minor --pre rc` → `vX.Y.Z-rc.1`; ulangi perintah
  yang sama untuk `rc.2`. Promosi: `./task release minor` dengan inti versi sama.
- Tag **tidak** dibuat di GitHub UI; kalau dibuat di sana, workflow menolak karena
  isi tag tidak cocok dengan `VERSION`.
- Jangan jalankan `--push` sebelum gate R4 lulus dan backup terbaru diverifikasi.

## 7. Jebakan yang sudah diketahui

| Jebakan | Tindakan |
|---|---|
| `nimble.lock` mematikan path global | jangan dibuat; pakai pin persis + `deps-check` |
| nimcache dipakai bersama antar-worktree | `./task` menyetel `--nimcache` per worktree (T-018) |
| Mummy default `serverThreads` = core×10 | pool DB dihitung dari `serverThreads`, bukan angka tetap |
| `db_connector` meng-escape, bukan bind, dan NULL jadi `""` | binder `PQexecParams` (T-004), termasuk NULL & operator jsonb `?` |
| migrasi dijalankan dua agen bersamaan | hanya `tools/dbtools`; satu pemilik migrasi per waktu |
| DB dev tercampur data uji antar agen | satu **database** per worker (`bm2_<agent>`) + guard prefiks `bm2_` |
| Mummy + ORC pernah SIGSEGV | `--mm:atomicArc` sejak hari pertama |
| Waktu tidak deterministik | `MAJADU_NOW` sejak test pertama; kolom `now()` di DB dinormalisasi di parity |
| Instance kosong tidak bisa boot | `T-103` bootstrap: platform_owner, komunitas pertama, seed config |
