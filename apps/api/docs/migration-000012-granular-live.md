# Migration 000012 — Granular Live (Clean Break)

> **Lokasi VPS:** `/srv/qouver/apps/majadu/migrations/000012_granular_live.sql`
> **Repo:** file ini adalah mirror dokumentasi — repo public tidak menyimpan SQL lengkap,
> tapi payload 000012 aman (tidak ada secret) sehingga didokumentasikan di sini.
> Apply di VPS via `psql` dengan role `majadu_app` (GRANTS sudah ada dari 000003).
>
> **Tujuan:** Menambahkan per-entity version, tabel idempotency persistent, dan outbox
> untuk SSE durable. Semua perubahan **additive & backward-compatible** — `PUT` snapshot
> lama tetap jalan sebelum granular diaktifkan.

## SQL (000012_granular_live.sql)

```sql
-- 000012_granular_live.sql — granular live: per-game version, idempotency, outbox
-- Additive, idempotent (IF NOT EXISTS). Aman di-apply di bm_dev lalu bm.

-- 1) Per-game version + updated_at untuk OCC granular
ALTER TABLE scheduled_games
  ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- Trigger updated_at (reuse function set_updated_at() dari 000001)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_scheduled_games_updated_at') THEN
    CREATE TRIGGER trg_scheduled_games_updated_at
      BEFORE UPDATE ON scheduled_games
      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;
END $$;

-- Backfill existing rows: version=1 sudah via DEFAULT

-- 2) Idempotency keys persistent (menggantikan in-memory map di handler)
CREATE TABLE IF NOT EXISTS idempotency_keys (
  session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  key TEXT NOT NULL,
  response JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (session_id, key)
);
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_expires_at ON idempotency_keys(expires_at);

-- Cleanup job: bisa via cron atau ticker Go (DELETE WHERE expires_at < now())
-- GRANTS: majadu_app sudah punya DML via 000003, tapi pastikan:
-- GRANT SELECT, INSERT, DELETE ON idempotency_keys TO majadu_app;

-- 3) Outbox untuk SSE durable (event sourcing lite)
CREATE TABLE IF NOT EXISTS outbox_events (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  aggregate TEXT NOT NULL, -- 'game' | 'player' | 'session'
  aggregate_id TEXT NOT NULL, -- '0-0' | player_ref | session share_code
  event_type TEXT NOT NULL, -- 'score_set' | 'played_toggled' | 'absent_set' | 'swap' | 'session_patched'
  payload JSONB NOT NULL,
  version BIGINT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_outbox_events_session_id ON outbox_events(session_id, id);

-- GRANTS serupa
-- GRANT SELECT, INSERT ON outbox_events TO majadu_app;
-- GRANT USAGE, SELECT ON SEQUENCE outbox_events_id_seq TO majadu_app;

-- 4) Notify channel tidak perlu DDL — BE pakai pg_notify('majadu_events', json)
```

## Cara Apply (VPS)

```bash
ssh user@198.51.100.10
psql "postgres://majadu_app:***@127.0.0.1:5432/qouver?search_path=bm_dev" -f /srv/qouver/apps/majadu/migrations/000012_granular_live.sql
# ulangi untuk bm (prod) saat ready
psql "postgres://majadu_app:***@127.0.0.1:5432/qouver?search_path=bm" -f /srv/qouver/apps/majadu/migrations/000012_granular_live.sql
```

## Verifikasi

```sql
\d scheduled_games -- harus ada version, updated_at
\d idempotency_keys
\d outbox_events
SELECT * FROM scheduled_games LIMIT 1; -- version=1
```

## Backward Compatibility

- `Store.Save` (snapshot) tetap jalan — tidak butuh `version` per game.
- `Store.Load` tidak SELECT `version` baru sampai Fase 1 aktif — jadi aman sebelum migration.
- Idempotency in-memory tetap jalan sebagai fallback jika tabel belum ada (BE cek `pgcode == undefined_table`).
