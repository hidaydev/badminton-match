# Catatan rekayasa

Rencana rewrite backend Go → Nim sudah selesai: `2.0.0` memakai runtime Nim dan
menjadi acuan. Dokumen rencana lamanya (`BRD`, `PRD`, `TECH-SPEC`, `BACKLOG`,
`EXECUTION`, `CROSS-CHECK`, `REVIEW-scrum`, `FROZEN`, `CHANGELOG-frozen`) dihapus
dari working tree setelah rilis; isinya tetap ada di riwayat git:

```bash
git log --all -- docs/plan/
```

Yang tersisa di sini masih dipakai:

| Berkas | Isi |
|---|---|
| [`rc-environment.md`](rc-environment.md) | lingkungan RC: branch, domain, port, deploy, cutover |
| [`scoring-presets.md`](scoring-presets.md) | preset scoring dan arti angkanya |
| [`deps-format.md`](deps-format.md) | format `deps.lock` dan aturan pin |
| [`contract-change.md`](contract-change.md) | alur perubahan kontrak (T-016) |
| [`ADR-011.md`](ADR-011.md) | keputusan P0 |
| [`memos/`](memos/) | enam memo ahli (stack, security, data, API, CI/CD, QA) — referensi historis |

Acuan runtime ada di [`docs/handbook/`](../handbook/README.md); prosedur rilis di
[`docs/ops/release.md`](../ops/release.md).