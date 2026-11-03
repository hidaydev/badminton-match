# apps/api — Majadu Backend (Go)

Backend Go untuk Majadu — bagian dari monorepo `badminton-match` (lihat
[`README.md`](../../README.md)). Menggantikan PostgREST RPC (Supabase) sebagai
satu-satunya backend; keputusan arsitektur di
`docs/handbook/backend-go-decision.md`.

## Stack

- Go 1.26, stdlib `net/http` (Go 1.22+ routing) — tanpa framework HTTP
- `pgx/v5` untuk Postgres (schema `bm`)
- Papan peringkat **rank points** (server-authoritative, idempotent, auditable)
- Spesifikasi REST parsial di [`api/openapi.yaml`](api/openapi.yaml) — 16 dari 48
  route terdaftar; daftar route lengkap ada di [`cmd/server/main.go`](cmd/server/main.go)

## Struktur

```
cmd/server/              # entrypoint
internal/config/         # env + godotenv (.env dev lokal) + validasi strict
internal/db/             # koneksi pool pgx
internal/domain/         # tipe + transform + validasi + ranking math (poin, 8-tier)
internal/store/          # akses DB: write/read-path Go, rating ingest/revert/rebuild
internal/handler/        # HTTP handlers (REST)
internal/middleware/     # CORS, logging (slog), panic recovery, rate limit
internal/httperr/        # error envelope JSON konsisten
internal/build/          # versi binary (ldflags)
api/openapi.yaml         # spec REST parsial (16 dari 48 route)
```

> **SQL migrations** — `000001`–`000012` TIDAK di repo GitHub (sengaja — kode repo
> public). Tersimpan di VPS: `/srv/qouver/backups/archive/2026-09-03/majadu-migrations/`.
> `000013`–`000023` didokumentasikan di [`docs/backend/`](../../docs/backend/).

## Endpoint (ringkas)

Base path produksi: `https://api.qouver.com/majadu` (prefix di-strip Caddy —
Go backend melihat path bersih tanpa prefix).

| Method | Path | Fungsi |
|---|---|---|
| `GET` | `/healthz` · `/readyz` · `/version` | liveness / readiness / build info |
| `POST` / `GET` | `/sessions` | create / list |
| `GET` / `PUT` / `PATCH` / `DELETE` | `/sessions/{id}` | get / full-snapshot update / patch / **admin** delete (draft only) |
| `POST` | `/sessions/{id}/lock` | **admin** — kunci sesi |
| `POST` | `/sessions/{id}/unlock` · `/delete` | **admin** — unlock / delete (status apa pun + rating cleanup + rebuild) |
| `GET` / `POST` | `/players` | list / register (opsional tier 8) |
| `GET` | `/players/{name}/stats` | statistik karier (session + classic + void-filtered) |
| `PATCH` | `/players/{playerId}/tier` · `/name` | **admin** — ubah tier 8 (+rebuild) / rename (alias lama disimpan) |
| `DELETE` | `/players/{playerId}` | **admin** — hapus pemain (+rebuild; `?force=true` bila ada riwayat) |
| `GET` / `POST` | `/tournaments` | list / create (classic \| team) |
| `GET` / `PUT` / `PATCH` | `/tournaments/{id}` | get / update snapshot |
| `POST` | `/tournaments/{id}/delete` | **admin** — hapus + rating cleanup + rebuild |
| `POST` | `/ratings/ingest-{session,tournament}` | **admin** — hitung & catat rating dari sumber |
| `POST` | `/ratings/revert-{session,tournament}` | **admin** — cabut source + full rebuild |
| `POST` | `/ratings/rebuild-all` · `/replay-all` · `/replay-source` | **admin** — recompute semua / replay massal / replay per sumber |
| `POST` | `/ratings/sources/{sourceId}/finalize` | **admin** — gate ingest tournament |
| `POST` | `/ratings/achievements/backfill` | **admin** — isi ulang badge |
| `GET` | `/rankings` · `/rankings/players/{playerId}` · `/ratings/players/{playerId}` · `/ratings/players/{playerId}/achievements` · `/ratings/sources` | publik — read path 8-tier + papan poin |

**Live ops granular** (grand-revamp, kontrak utama untuk mutasi session):

| Method | Path | Fungsi |
|---|---|---|
| `GET` / `PATCH` | `/sessions/{id}/games/{gameKey}` | read / ubah skor 1 game (row-level OCC + `If-Match` per game) |
| `PATCH` | `/sessions/{id}/games/{gameKey}/skip` | skip per game (skor dipertahankan; pemain tidak dapat rating) |
| `PATCH` | `/sessions/{id}/absent` | tandai pemain absent |
| `POST` | `/sessions/{id}/swap` | swap pemain/tim/game slot |
| `GET` | `/sessions/{id}/events` | replay event (outbox/SSE) |

Semua endpoint **admin** memakai `Authorization: Bearer MAJADU_ADMIN_TOKEN`
(middleware `AdminGuard`). Rating read path publik.

> `PUT /sessions/{id}` (full snapshot) adalah kontrak **legacy/deprecated** untuk
> live ops (`X-Snapshot-Deprecated: true`) — tetap dipakai fase setup/generate.
> Logika mutasi live memakai granular di atas; server memvalidasi row-level.

Concurrency: optimistic via header `If-Match: "v{n}"` / response `ETag`;
advisory locks (`pg_advisory_xact_lock`) + `SELECT ... FOR UPDATE NOWAIT`.

## Menjalankan

```bash
cp .env.example .env   # isi DATABASE_URL + MAJADU_DB_SCHEMA
go run ./cmd/server    # atau: make run
```

Prod: env dari systemd/podman `EnvironmentFile` (mode 600), bukan `.env`.

## Test

```bash
make check                 # vet + fmt + unit test
# integration test (butuh tunnel ke Postgres VPS):
MAJADU_TEST_DATABASE_URL="postgres://majadu_app:...@localhost:15432/bm_test" \
  MAJADU_TEST_DB_SCHEMA=bm_test make test-integration
# (buat DB scratch sendiri, mis. bm_test — jangan pakai bm prod)
```

> **CI:** `go test ./...` di GitHub Actions **tidak** menjalankan integration test
> (runner tidak punya DB ber-schema; migrasi privat tidak di repo). Job akan menampilkan
> warning eksplisit saat `MAJADU_TEST_DATABASE_URL` kosong supaya CI hijau tidak
> disalahartikan. Kalau secret `MAJADU_TEST_DATABASE_URL` (+ var `MAJADU_TEST_DB_SCHEMA`)
> di-set, integration test otomatis ikut jalan.

## DB role & schema

Akses DB memakai role khusus **`majadu_app`** (bukan superuser):
- kredensial disimpan di VPS saja (file env mode 600, TIDAK pernah di repo ini)

**Write-path session** dijalankan Go langsung ke tabel dalam satu transaksi
(row-level OCC, granular) — butuh privilege tabel; GRANT di migration `000003`.

**Read-path session/player juga Go** (rebuild snapshot, list sessions/players,
player stats — diverifikasi identik via `TestIntegrationReadPathParity`):
GRANT SELECT tabel tournament di `000004` (stats membaca tabel tournament
langsung).

**Tournament juga sudah Go** (write + read + register pemain — diverifikasi via
`TestIntegrationTournamentParity`): GRANT DML di `000005`.

**Sisa fungsi SQL**: hanya `normalize_player_name` (dipakai CHECK constraint
`player_aliases`) + utilitas `delete_player` / trigger `set_updated_at`. Semua
logika bisnis (session, player, tournament, **rating**) sudah 100% di Go.

**Papan poin & bookkeeping**: `rating_deltas` menyimpan fakta pertandingan
(`event_id`/`player_id`/`team`/`outcome`); `rating_players` hanya bookkeeping
(`games_played`, `wins`, `losses`, `last_played_at`). Poin dihitung saat baca dari
window bergulir 12 minggu (best 10 entri) dengan config `rank_*` di `rating_config`
(`000018`, `000022`), snapshot gerakan papan di `rank_snapshots` (`000019`), dan tier
sticky di `players.tier`. Mesin Glicko beserta tabel musim di-drop di `000020`
(2026-09-29).

**Schema via `MAJADU_DB_SCHEMA` (env), BUKAN hardcode di SQL.** Store memakai
kueri tanpa prefix schema; `search_path` diarahkan per-koneksi. Hanya ada satu
branch aktif (`main`) → `MAJADU_DB_SCHEMA=bm`.

## Deploy

**Arsitektur (webhook, pola sds-monorepo):** push ke `main` → GitHub webhook
(`https://api.qouver.com/hooks/majadu-monorepo`) → `webhook.service` di VPS →
`/srv/qouver/apps/majadu/scripts/deploy-vps.sh` → `podman build` image **lokal**
(`localhost/majadu-api:local`) → restart quadlet `majadu-api` → Caddy TLS.

```
Vercel (frontend)                       VPS api.qouver.com (Caddy)
main → apps/web (Root Directory)        main → https://api.qouver.com/majadu → 127.0.0.1:8080 (bm)
```

**Artefak di `ops/` (root monorepo):**
- `systemd/majadu-api.container` — quadlet systemd unit (Image=localhost/majadu-api:local, Pull=never)
- `scripts/deploy-vps.sh` — script deploy webhook (source of truth; server copy di `/srv/qouver/apps/majadu/scripts/`)
- `webhook/webhook.json` — placeholder rule webhook (secret asli hanya di VPS, chmod 600)
- `env/prod.env.example` — template env (secret diisi hanya di VPS)
- `caddy/Caddyfile.api.qouver.com` — snippet Caddy (strip prefix `/majadu`)

**Update:**
- Push `main` → webhook trigger (HMAC-SHA256) → build lokal + restart. Deploy hanya
  jika `apps/api/` berubah (guard `ref=refs/heads/main` di script).
- Rollback: image lokal sebelumnya masih ter-cache sampai `podman image prune` (01:30).

## Branch plan

- `main` — satu-satunya branch aktif (prod, schema `bm`). Branch `dev` di-sunset.

## License

MIT — see [LICENSE](LICENSE).
