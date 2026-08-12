# Migrations

Schema database `bm` / `bm_dev` — dipegang repo ini (backend owns schema).

## Isi

| File | Isi |
|---|---|
| `000001_functions.sql` | 23 fungsi Postgres (get/publish/list session, player, tournament, validasi) |
| `000002_schema.sql` | 13 tabel + constraint + index + trigger + grants + REVOKE PUBLIC pada fungsi admin |

## Skema target

File ini di-generate dari state `bm_dev` di VPS (schema di-rename `bm_dev` → `bm`).
Jadi **kanonik = `bm`** (prod). Untuk `bm_dev` (dev), apply dengan rename schema
`bm` → `bm_dev` — dilakukan di script provisioning/deploy (pola yang sama dengan
`vps-01-postgres.sh` di repo badminton-match).

## Cara apply (sementara — manual via psql)

Urutan wajib: **functions dulu, baru schema** (constraint `player_aliases` CHECK
mereferensikan `normalize_player_name`).

```bash
# prod (bm)
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f migrations/000001_functions.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f migrations/000002_schema.sql

# dev (bm_dev) — tambahkan rename schema
sed 's/\bbm\b/bm_dev/g' migrations/000001_functions.sql | psql "$DATABASE_URL_DEV" -v ON_ERROR_STOP=1
sed 's/\bbm\b/bm_dev/g' migrations/000002_schema.sql | psql "$DATABASE_URL_DEV" -v ON_ERROR_STOP=1
```

> TODO (saat podman provisioning): mekanisme migrate otomatis (runner sederhana
> dengan tabel `schema_migrations`, dijalankan saat container start).
