# Local development database

PostgreSQL 18.6 from Homebrew is the default; no container is required.

```
./task dev-db          # create roles, bm2_dev and bm2_template
./task dev-db          # safe to run again
ops/dev/reset.sh w1    # create bm2_w1 from bm2_template
```

`pg-up.sh` writes three passwords to `.env.local` (mode 600, gitignored) the
first time it runs: `BM2_OWNER_PASSWORD`, `BM2_APP_PASSWORD`,
`BM2_ETL_PASSWORD`. Override the file with `MAJADU_DEV_ENV`.

Connection string for the application:

```
MAJADU_PG_DSN=postgresql://sachiel@127.0.0.1:5432/bm2_dev
```

Roles:

| Role | Purpose |
|---|---|
| `bm2_owner` | DDL and migrations |
| `bm2_app` | application DML |
| `bm2_etl` | reads staging, writes `bm2` during cutover |

`bm2_template` is marked as a template. Worker databases are recreated with
`ops/dev/reset.sh <suffix>`; the suffix must be lowercase letters, digits or
underscore, and `dev`/`template` are refused.

The script never writes to `bm` and revokes `CONNECT`/`ALL` on it from the bm2
roles when the archive database exists (O-41).
