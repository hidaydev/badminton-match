# Roadmap

Status per **2026-11-05**. Riwayat perubahan ada di git history; rencana beku ada
di [`../plan/`](../plan/README.md) dan tidak diubah handbook ini.

## ✅ Selesai

- **Backend v2 (Nim 2.4)** — modul `account`, `community`, `player`, `session`,
  `tournament`, `rating`, `achievement`, `share`, `platform`; entrypoint
  `apps/api/src/main.nim`.
- **Kontrak 75 operasi** — `core.yaml` + `community.yaml` → `api.yaml`,
  `routes_gen.nim`, klien TS, fingerprint (`packages/contracts/openapi`).
- **Skema v2** — 22 migrasi (`0001`–`0022`), 36 key config, seed config dan
  achievement.
- **Auth & komunitas** — OIDC + cookie sesi, membership `member`/`host`/`admin`,
  invite, join request, settings, audit append-only, platform owner.
- **Sesi** — API baca/tulis lengkap (jadwal, skor, skip, absent, swap, lock/unlock,
  share) dengan `If-Match` + `Idempotency-Key`; klasemen dihitung server; UI host
  dan halaman share publik sudah ada.
- **Papan poin** — proyeksi v1 dari game: window 12 minggu, best 10 entri
  (satu per sesi/turnamen), pengali tier, filter tier, detail pemain +
  achievement. `min_sessions` menyaring papan dan bukti tipis hanya ditandai.
- **Pengalaman v1 di atas API v2** — tree legacy dipulihkan di
  `apps/web/src/legacy/`, akses berbasis role (`member`/`host`/`admin`), skip
  per pemain per game, dan medali event v1 + rank-streak di rak pemain.
- **Turnamen** — classic (16 pasangan, 4 grup, 32 match) dan team (6×6, 9 match grup
  + final, 3 partai), editor FE + ingest rating admin.
- **Ekspor** — post/story dari sesi atau turnamen, ukuran dari config.
- **Pemain** — daftar, klaim/lepas klaim, merge, antrean admin.
- **Realtime** — WebSocket ticket sekali pakai, fan-out in-memory (API).
- **Gate** — `check`, `test`, `contract-check`, `coverage`, `parity`, `pnpm
  check:web`, `e2e` (iPhone 17 + POCO F5), CI 7 job + gate.
- **Ops** — deploy/cutover/rollback/backup/restore/smoke, Quadlet hardened, Caddy
  handler `/majadu`, alert unit, harness rehearsal.
- **Rilis** — SemVer 2.0.0, CHANGELOG, tag SSH-signed, image sekali di CI, Release
  ber-digest.
- **Dekomisi Go v1** — source dihapus; rollback memakai `:v1-final`.

## ⏳ Berikutnya (di luar 88 task)

| # | Item | Kenapa |
|---|---|---|
| 1 | **Klien WebSocket di FE** | Endpoint ticket + upgrade sudah siap, tetapi halaman sesi masih memuat state sekali; host lain tidak terlihat sampai refresh. |
| 2 | **Produsen `platform.outbox`** | Realtime masih in-memory → API wajib satu instance; outbox sudah ada dan dibersihkan janitor, belum dipakai. |
| 3 | **Snapshot harian** | `rating.snapshots` hanya ditulis manual; panah pergerakan butuh snapshot baru setiap hari seperti job v1. |
| 4 | **Naikkan coverage** | Lihat `coverage-baseline.json`; ratchet hanya menahan, tidak menaikkan. |
| 5 | **Putuskan selisih 4 pemain** | Salma, Youri, Zaid, Firda beda dari snapshot v1 karena ledger v1 sesi 2026-10-31 basi; v2 menghitung dari game terkini. Perlu keputusan produk (ikuti v1 atau data terkini). |

## 🚧 Operasional yang belum selesai

- **T-063 rehearsal** — harness + gate siap, `timings.json` masih `not_run`;
  butuh Podman dan jendela maintenance di VPS.
- **Bukti VPS** (T-060/061/065) — `caddy validate` produksi, parsing Quadlet,
  `podman pull` digest, rollback ber-stopwatch.
- **T-074 soak** — 1 juta request + 50 watcher; ditunda pemilik, belum ada harness.
- **T-082** — hapus image `:v1-final` setelah 30 hari observasi pasca-cutover.
- **T-108** — force-push riwayat yang sudah di-rewrite **ditunda** atas keputusan
  pemilik; hook lokal sudah menolak `docs/audits` dan `docs/plan/reviews` kembali.

## Catatan

- Deploy: push `main` → webhook → `ops/scripts/deploy-vps.sh`. Selama env produksi
  masih menunjuk `bm`, script berhenti sebelum menyentuh container (cutover gate).
- Backup/restore/cutover/rollback sudah ada di `ops/scripts/` dan didokumentasikan
  di [`../ops/cutover.md`](../ops/cutover.md); prosedurnya belum dieksekusi di VPS.
- Test: `./task check` · `./task test` (dengan `MAJADU_PG_DSN`) · `./task coverage`
  · `./task e2e` · `pnpm check:web`.
