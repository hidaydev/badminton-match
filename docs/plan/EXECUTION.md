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
- jangan mengubah packages/contracts/openapi/api.yaml (lewat T-016)
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
- `dbtools verify` bersih pada `0001`–`0004`.
- `./task build` menghasilkan binary yang berjalan dan merespons `/healthz`.
- `./task contract-gen` menghasilkan 59 operasi dan `git diff --exit-code` bersih.
- `./task mock-api` melayani FE.
- Definisi CI lolos parse + skema (dan `actionlint` bila terpasang — belum ada di mesin ini);
  `./task ci` hijau lokal.

## 6. Jebakan yang sudah diketahui

| Jebakan | Tindakan |
|---|---|
| `nimble.lock` mematikan path global | jangan dibuat; pakai pin persis + `deps-check` |
| nimcache dipakai bersama antar-worktree | `./task` menyetel `--nimcache` per worktree (T-018) |
| Mummy default `serverThreads` = core×10 | pool DB dihitung dari `serverThreads`, bukan angka tetap |
| `db_connector` meng-escape, bukan bind, dan NULL jadi `""` | binder `PQexecParams` (T-004), termasuk NULL & operator jsonb `?` |
| migrasi dijalankan dua agen bersamaan | hanya `tools/dbtools`; satu pemilik migrasi per waktu |
| DB dev tercampur data uji antar agen | satu skema per worker + guard nama wajib `bm2_` |
| Mummy + ORC pernah SIGSEGV | `--mm:atomicArc` sejak hari pertama |
| Waktu tidak deterministik | `MAJADU_NOW` sejak test pertama; kolom `now()` di DB dinormalisasi di parity |
| Instance kosong tidak bisa boot | `T-103` bootstrap: platform_owner, komunitas pertama, seed config |
