# CHANGELOG Pembekuan

Hanya perubahan yang diizinkan `FROZEN.md` yang dicatat di sini: perbaikan fakta,
klarifikasi acceptance untuk task yang belum dimulai, dan pembaruan hash.

Format: `YYYY-MM-DD | berkas | jenis | alasan`.

| Tanggal | Berkas | Jenis | Alasan |
|---|---|---|---|
| 2026-11-03 | `BRD/PRD/TECH-SPEC/BACKLOG/EXECUTION/CROSS-CHECK/README` | baseline | Gate final putaran 17 ditutup; hash baseline dicatat di `FROZEN.md` |
| 2026-11-03 | `BACKLOG.md`, `README.md`, `FROZEN.md` | klarifikasi | Keputusan pemilik: `docs/plan/reviews/` tidak diterbitkan; T-108 diperluas mencakup reviews + `.local/plan-reviews`, tanpa task baru |
| 2026-11-03 | `TECH-SPEC.md` | perbaikan fakta | §4B menyuruh archlint menolak semua `?`, padahal itu mematahkan operator `jsonb ?` dan acceptance T-004; diganti dengan larangan rewriting placeholder |
| 2026-11-03 | `BACKLOG.md` | klarifikasi | Pemilik memilih timezone default `Asia/Jakarta` di registry L1 (`community.default_timezone`), bukan wajib saat create; T-090 belum dimulai |
| 2026-11-03 | kontrak | klarifikasi | Pemilik mengonfirmasi daftar 73 operasi (11 ranking, 14 community) dan model satu pasang skor per game; tidak ada perubahan dokumen |
