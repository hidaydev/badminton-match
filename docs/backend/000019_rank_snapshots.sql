-- =============================================================================
-- 000019 — Snapshot poin ranking (movement ^/v di papan)
--
--   Papan poin dihitung SAAT BACA (§4.6), jadi tidak ada jejak "posisi
--   sebelumnya" untuk dibandingkan. Tabel ini menyimpan posisi papan pada
--   tiap tanggal acuan (as_of = tanggal event rating terakhir saat snapshot
--   diambil), sehingga selisih rank bisa ditampilkan tanpa menghitung ulang
--   papan versi lama.
--
--   Ditulis oleh ticker auto-ingest (30 menit) — idempoten lewat PK
--   (as_of, player_id): dalam satu hari, snapshot terbaru menimpa yang lama.
--
--   Gerakan = rank(as_of sekarang) - rank(as_of snapshot sebelumnya).
--   Positif = naik (rank mengecil). Pemain yang baru muncul di papan
--   (belum ada di snapshot sebelumnya) → belum ada gerakan (NULL).
--
--   Additive + idempotent. Angka poin disimpan apa adanya pada saat snapshot
--   (numeric, tanpa pembulatan) supaya bisa dipakai lagi untuk tren nanti.
-- =============================================================================
BEGIN;

CREATE TABLE IF NOT EXISTS bm.rank_snapshots (
  as_of       date        NOT NULL,
  player_id   uuid        NOT NULL REFERENCES bm.players(id) ON DELETE CASCADE,
  rank        int         NOT NULL,
  points      numeric     NOT NULL,
  captured_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (as_of, player_id),
  CONSTRAINT rank_snapshots_rank_ck CHECK (rank > 0)
);

-- Papan dibaca per as_of; urutan rank hanya relevan di dalam satu as_of.
CREATE INDEX IF NOT EXISTS idx_rank_snapshots_as_of_rank
  ON bm.rank_snapshots(as_of, rank);

GRANT SELECT, INSERT, UPDATE, DELETE ON bm.rank_snapshots TO majadu_app;

COMMIT;
