# Docs

Dokumentasi runtime, operasi, dan proses hari ini. Semua berkas memakai huruf
kecil dan tanda hubung; `README.md` satu-satunya pengecualian.

## Start Here

- [`handbook/README.md`](handbook/README.md) — index handbook
- [`handbook/current-status.md`](handbook/current-status.md) — kondisi sekarang, infrastruktur, testing
- [`handbook/architecture.md`](handbook/architecture.md) — arsitektur FE/BE, WebSocket, PWA
- [`handbook/data-model.md`](handbook/data-model.md) — skema database v2 (`bm2`) dan bentuk data API

## Peta direktori

| Folder | Isi |
|---|---|
| `handbook/` | runtime: produk, arsitektur, skema, rute, status, roadmap, scoring preset, format `deps.lock` |
| `ops/` | akses dan insiden, rilis, OAuth, cutover, hook pre-push, lingkungan RC |
| akar `docs/` | [`decisions.md`](decisions.md), [`design-system.md`](design-system.md), [`privacy.md`](privacy.md) |

## Konvensi

- Satu fakta satu tempat: skema di `data-model.md`, status dan angka test di
  `current-status.md`, prioritas di `roadmap.md`.
- Dokumen internal boleh bahasa Indonesia; kode dan komentar tetap bahasa Inggris.
- Dokumen yang mendeskripsikan era lama atau rencana yang sudah selesai tidak
  disimpan di working tree. Ambil dari riwayat: `git log --all -- docs/`.