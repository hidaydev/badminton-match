# Handbook

Dokumen di folder ini menjelaskan **runtime v2** (backend Nim + frontend React)
yang ada di repo hari ini.

## Start Here

- [current-status.md](current-status.md) — kondisi repo, testing, infrastruktur
- [product-overview.md](product-overview.md) — deskripsi produk dan area fitur
- [architecture.md](architecture.md) — arsitektur Nim/React, kontrak, auth, WebSocket

## Reference

- [data-model.md](data-model.md) — skema database `bm2`, tabel, constraint, config
- [features-and-routes.md](features-and-routes.md) — rute web dan 75 operasi API
- [scoring-presets.md](scoring-presets.md) — aturan dan angka preset scoring
- [deps-format.md](deps-format.md) — format `deps.lock` dan aturan pin
- [roadmap.md](roadmap.md) — yang sudah ada dan prioritas berikutnya
- [design-system.md](../design-system.md) — warna, tipografi, komponen, token

## Terkait

- [`../ops/`](../ops/) — rilis, operasi, OAuth, cutover
- [`../ops/rc-environment.md`](../ops/rc-environment.md) — lingkungan RC
- [`../decisions.md`](../decisions.md) — catatan keputusan arsitektur
- Dokumen historis (rencana rewrite, ADR Go v1, design spec lama) ada di git
  history: `git log --all -- docs/`.