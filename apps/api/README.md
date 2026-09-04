# apps/api — Majadu Backend (Go)

Backend Go untuk Majadu — bagian dari monorepo `badminton-match` (lihat
[`README.md`](../../README.md)). Menggantikan PostgREST RPC (Supabase) sebagai
satu-satunya backend; keputusan arsitektur di
`docs/handbook/backend-go-decision.md`.

## Stack

- Go 1.26, stdlib `net/http` (Go 1.22+ routing) — tanpa framework HTTP
- `pgx/v5` untuk Postgres (schema `bm`)
- Rating engine **Glicko-1-lite** (server-authoritative, idempotent, auditable)
- Kontrak RESTful didokumentasikan di [`api/openapi.yaml`](api/openapi.yaml)

## Struktur

```
cmd/server/              # entrypoint
internal/config/         # env + godotenv (.env dev lokal) + validasi strict
internal/db/             # koneksi pool pgx
internal/domain/         # tipe + transform + validasi + rating math (Glicko, 8-tier)
internal/store/          # akses DB: write/read-path Go, rating ingest/revert/rebuild
internal/handler/        # HTTP handlers (REST)
internal/middleware/     # CORS, logging (slog), panic recovery, rate limit
internal/httperr/        # error envelope JSON konsisten
internal/build/          # versi binary (ldflags)
api/openapi.yaml         # kontrak REST resmi
```

> **SQL migrations** — `000001`–`000011` TIDAK di repo GitHub (sengaja — kode repo
> public). Tersimpan di VPS: `/srv/qouver/apps/majadu/migrations/`.
> Migrasi terbaru (`000012`+ catatan, `000013`/`000014` SQL) didokumentasikan di
> [`docs/backend/`](../../docs/backend/).

## Endpoint (ringkas)

Base path produksi: `https://api.qouver.com/majadu` (prefix di-strip Caddy —
Go backend melihat path bersih tanpa prefix).

| Method | Path | Fungsi |
|---|---|---|
| `GET` | `/healthz` · `/readyz` · `/version` | liveness / readiness / build info |
| `POST` / `GET` | `/sessions` | create / list |
| `GET` / `PUT` / `PATCH` / `DELETE` | `/sessions/{id}` | get / full-snapshot update / patch / delete (draft only) |
| `POST` | `/sessions/{id}/lock` | kunci sesi (host flow) |
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
| `POST` | `/ratings/rebuild-all` · `/season` | **admin** — recompute semua / close & start season |
| `POST` | `/ratings/sources/{id}/finalize` | **admin** — gate ingest tournament |
| `GET` | `/ratings/leaderboard` · `/players/{id}` · `/sources` · `/seasons` · `/seasons/{id}/standings` | publik — read path 8-tier |

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
MAJADU_TEST_DATABASE_URL="postgres://majadu_app:...@localhost:15432/bm_test" go test ./internal/store/
# (buat DB scratch sendiri, mis. bm_test — jangan pakai bm prod)
```

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

**Rating engine & season**: tabel `rating_*` (events/deltas/players/sources/config/seasons)
dari migration `000008`–`000011`; unifikasi **8-tier** di `000011`
(`players.tier` single source, `rating_players.class` di-drop). RebuildAll
recomputs rating_players dari events (transitivity) — deterministik.

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

**Artefak di `deploy/` (root monorepo):**
- `majadu-api.container` — quadlet systemd unit (Image=localhost/majadu-api:local, Pull=never)
- `deploy-vps.sh` — script deploy webhook (source of truth; server copy di `/srv/qouver/apps/majadu/scripts/`)
- `webhook.json` — placeholder rule webhook (secret asli hanya di VPS, chmod 600)
- `env/prod.env.example` — template env (secret diisi hanya di VPS)
- `Caddyfile.api.qouver.com` — snippet Caddy (strip prefix `/majadu`)

**Update:**
- Push `main` → webhook trigger (HMAC-SHA1) → build lokal + restart. Deploy hanya
  jika `apps/api/` berubah (guard `ref=refs/heads/main` di script).
- Rollback: image lokal sebelumnya masih ter-cache sampai `podman image prune` (01:30).

## Branch plan

- `main` — satu-satunya branch aktif (prod, schema `bm`). Branch `dev` di-sunset.

## License

MIT — see [LICENSE](LICENSE).
