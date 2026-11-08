# Docs

Dokumentasi yang masih menggambarkan runtime, operasi, dan proses hari ini.
Dokumen historis — rencana rewrite, migrasi SQL v1, design spec fitur yang sudah
selesai — dihapus dari working tree; isinya tetap ada di riwayat git:

```bash
git log --all -- docs/
```

## Start Here

- [`handbook/README.md`](handbook/README.md) — index handbook
- [`handbook/current-status.md`](handbook/current-status.md) — kondisi sekarang, infrastruktur, testing
- [`handbook/architecture.md`](handbook/architecture.md) — arsitektur FE/BE, WebSocket, PWA
- [`handbook/data-model.md`](handbook/data-model.md) — skema database v2 (`bm2`) dan bentuk data API

## Isi direktori

### `handbook/`

Runtime v2: produk, arsitektur, skema, rute, status, roadmap.

### `ops/`

Cara menjalankan dan merilis: akses & insiden, rilis, OAuth, cutover, hook pre-push,
lingkungan RC.

### `plan/`

Yang masih dipakai setelah rewrite selesai: lingkungan RC, aturan scoring preset,
dan format `deps.lock`.

### Akar `docs/`

- [`design-system.md`](design-system.md) — token, tipografi, pola UI
- [`privacy.md`](privacy.md) — data yang disimpan, retensi, dan anonymisasi
- [`DECISIONS.md`](DECISIONS.md) — catatan keputusan arsitektur

## Konvensi

- Satu fakta satu tempat: skema di `data-model.md`, status & angka test di
  `current-status.md`, prioritas di `roadmap.md`.
- Dokumen internal boleh bahasa Indonesia; kode dan komentar tetap bahasa Inggris.
- Detail historis ada di git history, bukan di working tree.