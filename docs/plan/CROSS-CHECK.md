# CROSS-CHECK — dokumentasi perencanaan

Tanggal: 2026-11-03
Metode: dua putaran terpisah. Putaran 1 menguji **klaim vs sumber** (kode, dump skema,
library). Putaran 2 menguji **dokumen vs dokumen** (angka, istilah, dependency, traceability).

Aturan yang dipakai: klaim tanpa sumber tidak masuk dokumen; klaim yang bertentangan
tidak dirata-ratakan, tapi dipilih satu dan alasannya ditulis.

---

## Putaran 1 — klaim vs sumber

| # | Klaim | Sumber yang diuji | Hasil |
|---|-------|-------------------|-------|
| 1 | 48 route di v1 | `main.go`, dihitung ulang otomatis | **benar** (48) |
| 2 | Skema `bm` = 26 tabel, 26 index, 4 fungsi | `pg_dump --schema-only` | **benar** |
| 3 | `GET /sessions` membocorkan `share_code` sebagai `id` | `session_admin.go:169-176,188` + `session.go:119-141` | **benar** |
| 4 | `PUT/PATCH/games/absent/swap` tanpa guard | `main.go:199-208` | **benar** |
| 5 | `POST /sessions` & `POST /tournaments` anonim | `main.go:196,231` | **benar** |
| 6 | `DELETE /sessions/{id}` & `lock` sebenarnya admin | `main.go:201-202` | **benar** (audit 05/01 sempat menyebut anonim; README sudah dikoreksi) |
| 7 | `rating_deltas` tanpa UNIQUE `(event_id, player_id)` | dump, `rating_deltas_pkey` | **salah** — PK sudah ada |
| 8 | Index urut 4 kolom tidak ada | dump, `rating_events_order_uniq` | **salah** — sudah ada |
| 9 | `/ratings/rebuild-all` hilang dari route | `main.go:249` | **salah** — route ada, hanya openapi yang kurang |
| 10 | `Save()` mereset `scheduled_games.version` | `session_write.go:304-340` (DELETE+INSERT) | **benar** |
| 11 | `DeletePlayer` menghapus event semua peserta | `rating_admin.go:119-122` | **benar** |
| 12 | Achievement `tournament` masih ditulis | `store/achievement.go:577` | **benar** (memo/data-model awal salah) |
| 13 | Sparkline masih ada di UI | `grep -ri sparkline apps/web/src` = 0 | **salah** — sudah dihapus dari dokumen |
| 14 | `db_connector` meng-escape, bukan bind | `db_postgres.nim:118` (`dbQuote`) + `db_common` | **benar** |
| 15 | Mummy tidak mendukung SSE | `mummy-0.4.8` tanpa `text/event-stream` | **benar** |
| 16 | nimcrypto tanpa RSA | isi paket nimcrypto 0.7.3 | **benar** |
| 17 | `std/openssl` menyediakan `EVP_DigestVerify*` | `lib/wrappers/openssl.nim` | **salah** — hanya `EVP_DigestSign*`; dibutuhkan binding lokal |
| 18 | IP server bocor di repo | `ops/caddy/Caddyfile.api.qouver.com:3` | **salah** — `198.51.100.10` = RFC 5737 |
| 19 | `1.7 .local` dump tidak masuk git | `git check-ignore` | **benar** (ditambahkan) |

**Konsekuensi yang sudah diterapkan**

- TECH-SPEC §1 memuat tabel koreksi; empat temuan audit diturunkan statusnya.
- TECH-SPEC §7.2 & ADR-009 diubah dari "stdlib sudah punya" menjadi "butuh modul
  binding ±80–120 baris + spike".
- `data-model.md` dan `product-overview.md` di repo sudah dikoreksi lebih dulu
  (commit `08e93a8`) untuk achievement kind dan sparkline.
- Memo security memakai nama tabel `bm.player_ratings`; nama benar `bm.rating_players`
  (typo, tidak memengaruhi desain).

---

## Putaran 2 — dokumen vs dokumen

| # | Yang diuji | Hasil | Tindakan |
|---|------------|-------|----------|
| 1 | Aritmetika permukaan API: 48 − 7 − 2 + 9 | 48 | konsisten (TECH-SPEC §5) |
| 2 | Task ID yang dirujuk di `Depends` benar-benar ada | 48 task, 0 dangling | — |
| 3 | Task tanpa dependensi | hanya T-001 | disengaja |
| 4 | Setiap requirement PRD punya task | awalnya **1 dari 38** | ditambah §10 matriks traceability |
| 5 | Penamaan tautan: `share_links` (memo 03) vs `session.links` (memo 02) | **konflik** | dipilih `session.links` + `kind('view'\|'edit')`, dicatat di TECH-SPEC §4 |
| 6 | Verifikasi ID token: memo 01 (klaim saja) vs memo 02 (RS256) | **konflik** | diselesaikan di TECH-SPEC §7.2, ADR-009 tetap terbuka |
| 7 | Rute baru vs lama: `/rankings` diklaim baru? | **sudah ada di v1** (`main.go:255`) | tidak dimasukkan sebagai rute baru |
| 8 | Nomor migrasi di dokumen lama (`000013–000016`) | sudah dikoreksi ke `000023` di commit `08e93a8` | — |
| 9 | Istilah `publicId` vs `public_id` | dipakai `publicId` (JSON) / `public_id` (kolom) | konsisten dengan memo 04 |
| 10 | Gate per rilis R0–R4 ada di PRD dan BACKLOG | cocok | — |

---

## Putaran 2b — review peran (scrum master)

Lihat `REVIEW-scrum.md`. Temuan review diadopsi/ditolak secara eksplisit di bawah
(isi bagian ini diperbarui setelah review masuk).

| Temuan review | Keputusan |
|---------------|-----------|
| Task keamanan tanpa pemilik (rate limit, CSRF, idempotency, `/auth/*`) | diadopsi → T-075..T-078, AUTH-07..09 |
| T-006 terlalu besar, lingkup "26 tabel" salah | diadopsi → T-006a–d termasuk `auth.*`, `account.*`, `platform.idempotency_keys` |
| T-013 bergantung pada DB yang salah | diadopsi → T-014 (env v1 lokal) |
| `Owns` glob saling menabrak | diadopsi → semua ke file-level |
| FE tanpa edge ke kontrak, tanpa mock API | diadopsi → T-015, T-016 |
| Edge T-044 → T-028 | **ditolak** — papan publik |
| T-011 "hijau di PR" tanpa push | diadopsi (diubah) → `actionlint` + `./task ci` |
| T-060 acceptance sirkular dengan T-063 | diadopsi → drill dipindah |
| Dekomisi Go & keputusan freeze poin belum ada task | diadopsi → T-082, T-083 |

---

## Yang masih terbuka (butuh pemilik, bukan analisis)

1. Jendela P0 terbuka: berapa lama dapat diterima sebelum kontrol kompensasi dipasang?
2. Apakah penonton boleh menulis, atau baca saja?
3. Apakah host tanpa login tetap wajib ada setelah Google auth?
4. Urutan impor data: rilis pertama kosong, atau impor lebih dulu?
5. ADR-009: setuju menambah modul binding OpenSSL untuk verifikasi RS256?

---

## Batas kepercayaan dokumen ini

- Klaim baris 1–19 diuji pada 2026-11-03; setelah kode berubah, klaim bisa kedaluwarsa.
- Angka performa (p95, RSS, waktu compile) adalah **target**, bukan hasil pengukuran.
- Estimasi kapasitas agen (4 paralel) adalah heuristik, belum divalidasi pada repo ini.
