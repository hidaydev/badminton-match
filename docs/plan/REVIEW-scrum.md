# REVIEW — scrum master

Tanggal: 2026-11-03
Peran: delivery lead / scrum master (subagent, read-only)
Objek review: `BRD.md`, `PRD.md`, `TECH-SPEC.md`, `BACKLOG.md`, `memos/01..06`
Status: temuan sudah diadopsi/ditolak di `BACKLOG.md` §11

Catatan: reviewer berjalan dalam mode read-only, jadi berkas ini ditulis oleh
orchestrator dari temuannya. Isi temuan tidak diubah.

---

## 1. Dependency audit

Edge yang hilang atau salah:

| Task | Masalah | Keputusan |
|------|---------|-----------|
| T-006 | Satu task memuat 26 tabel + 7 perbaikan + tabel modul; memblokir T-020/024/040/042/050/051/064 | dipecah T-006a–d |
| T-013 | Bergantung pada T-007 (DB `bm2`), padahal capture butuh v1 | tambah T-014, edge T-014 → T-013 |
| T-028–T-030 | Tidak ada edge ke T-008/T-009 | ditambah, plus T-015 (mock) |
| T-046 | Tidak bergantung pada T-044 | ditambah |
| T-072 | Tidak bergantung pada T-029/T-030 | ditambah |
| T-074 | Tidak bergantung pada T-062 | ditambah |
| T-044 | Diusulkan bergantung T-028 | **ditolak** — papan publik, backend tidak butuh auth FE |

Tidak ditemukan siklus nyata. Edge "T-060 → T-063" bukan siklus, tapi acceptance
T-060 yang memakai hasil T-063; diperbaiki dengan memindahkan drill ke T-063.

## 2. File-collision audit

| Konflik | Keputusan |
|---------|-----------|
| T-001 `apps/api/` menelan `routes_gen.nim` (T-009), `auth_middleware.nim` (T-023), `live.nim` (T-027), `health.nim` (T-062), `tests/security/` (T-070) | `Owns` T-001 dipersempit ke `main.nim` + `server.nim` |
| T-062 `ops/` bertabrakan T-060/T-061 yang ditandai paralel | `ops/` dibagi per subdirektori; T-062 hanya `apps/api/src/health.nim` + satu skrip rotate |
| T-040 `modules/player/` vs T-041 `api.nim` | T-040 dipersempit ke `domain/` + `infrastructure/` |
| T-003 vs T-004 di `shared/platform-lib/` | T-003 kecuali `db/`, T-004 hanya `db/` |
| T-029 `queries/sessions*` dipakai T-030 | dipecah `sessions.read.ts` / `sessions.write.ts` |
| `api.yaml` tak berpemilik setelah T-008 | T-016 menjadi gerbang perubahan kontrak |

## 3. Coverage gap PRD → task

Awalnya 1 dari 38 requirement punya task. Yang benar-benar tidak punya pemilik:
rate limit per route, gerbang `Origin`/`Sec-Fetch-Site`, `idempotency_keys`,
`trusted_proxy`, dan tiga route `/auth/*`.

Keputusan: tambah AUTH-07..09 di PRD, task T-075..T-078, dan tabel traceability
di BACKLOG §10 (38 + 3 requirement kini terpetakan).

## 4. Sequencing risk

- Kontrak beku (T-008/T-009) harus selesai sebelum FE menyentuh API — sudah, lewat
  T-015/T-016.
- Korpus parity (T-013) harus dari v1, bukan dari skema baru — sudah, lewat T-014.
- Implementasi session (T-025) menunggu `bm2` inti (T-006a) dan kontrak (T-009);
  keduanya jalur kritis.
- Rating domain (T-042) bisa jalan lebih awal karena hanya butuh `platform-lib`.

## 5. Estimasi & batching

Task yang dianggap terlalu besar: T-006 (dipecah), T-001 (masih besar tapi tidak
bisa dipecah karena semua bergantung padanya), T-060 (dibiarkan; acceptance
dipersempit). T-071/T-073 bisa digabung bila waktu ketat, tapi dipisah agar
pemiliknya jelas.

## 6. DoR/DoD

Ambigu yang diperbaiki:

| Task | Sebelum | Sesudah |
|------|---------|---------|
| T-011 | "job hijau di PR" (mustahil tanpa push) | `actionlint` + `./task ci` lokal |
| T-044 | "p95 < 150 ms" tanpa dataset | dataset fixture 1 tahun |
| T-060 | rollback dibuktikan di task ini | guard diuji di sini, drill di T-063 |

## 7. Lima perubahan dengan dampak risiko terbesar

1. Tutup lubang keamanan yang tidak punya task (rate limit, CSRF, idempotency, `/auth/*`).
2. Pecah T-006 dan benahi rantai parity (T-014).
3. Hentikan klaim `Owns` global yang menabrak; perbaiki label paralel.
4. Beri pemilik untuk kontrak setelah T-008 + mock API sebelum FE.
5. Perbaiki edge hilang dan DoD yang tidak terverifikasi; tambah task dekomisi Go
   dan keputusan freeze poin.
