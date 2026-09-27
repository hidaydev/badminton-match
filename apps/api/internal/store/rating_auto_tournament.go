package store

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// AutoIngestTournaments — ingest otomatis turnamen yang sudah SELESAI tapi
// belum pernah di-ingest. Dipanggil ticker bersamaan dengan
// AutoIngestLockedSessions.
//
// Kenapa ini ada: sebelum 2026-09-27 ticker hanya menyapu tabel `sessions`,
// sehingga turnamen TIDAK PERNAH ter-ingest otomatis — turnamen klasik
// 23 Mei 2026 bahkan tidak punya satu baris pun di `rating_sources`
// (bukan ditolak; memang tidak pernah dicoba). Akibatnya tidak ada event
// `tournament_classic` sama sekali di riwayat rating.
//
// Definisi "selesai" (keputusan produk 2026-09-27, murni tanpa jaring waktu):
// SEMUA match sudah berskor.
//   - classic → `tournament_matches.score_a/score_b` terisi semua
//   - team    → semua `tournament_team_match_games.score_a/score_b` terisi
//
// Sengaja TANPA jaring `event_date + N hari`: pemilik sistem menyatakan data
// turnamen selalu lengkap. Bila di masa depan ada turnamen yang nyangkut,
// penambahannya murah (satu klausa OR di kandidat).
//
// Yang dilaporkan (observabilitas, bukan aturan): bila finalisasi terjadi
// saat masih ada match kosong, TIDAK mungkin — kandidat disaring lebih dulu.
// Jadi warning di sini hanya muncul untuk kasus tak terduga.
func (s *SessionStore) AutoIngestTournaments(ctx context.Context) (int, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT share_code
		FROM `+s.schema+`.tournaments t
		WHERE t.event_date >= (SELECT (value #>> '{}')::date FROM `+s.schema+`.rating_config WHERE key = 'season_start')
		  AND NOT EXISTS (
			SELECT 1 FROM `+s.schema+`.rating_sources rs
			WHERE rs.source_id = t.share_code AND rs.fingerprint != ''
		  )
		  AND (
			-- classic: WAJIB punya minimal satu match, dan tidak ada satu pun
			-- yang berskor kosong.
			-- PENTING: EXISTS(match) harus ada. Tanpa itu, turnamen yang belum
			-- punya match sama sekali akan lolos (NOT EXISTS pada himpunan
			-- kosong selalu TRUE) -> ter-finalisasi tanpa event sekalipun,
			-- dan karena rating_sources terisi, ia tidak akan pernah dicoba lagi.
			(t.format IS DISTINCT FROM 'team'
				AND EXISTS (
					SELECT 1 FROM `+s.schema+`.tournament_matches tm
					WHERE tm.tournament_id = t.id
				)
				AND NOT EXISTS (
					SELECT 1 FROM `+s.schema+`.tournament_matches tm
					WHERE tm.tournament_id = t.id
					  AND (tm.score_a IS NULL OR tm.score_b IS NULL)
				))
			OR
			-- team: idem untuk partai (bukan match — satu match tim berisi 3 partai)
			(t.format = 'team'
				AND EXISTS (
					SELECT 1 FROM `+s.schema+`.tournament_team_match_games g
					JOIN `+s.schema+`.tournament_team_matches m ON m.id = g.team_match_id
					WHERE m.tournament_id = t.id
				)
				AND NOT EXISTS (
					SELECT 1 FROM `+s.schema+`.tournament_team_match_games g
					JOIN `+s.schema+`.tournament_team_matches m ON m.id = g.team_match_id
					WHERE m.tournament_id = t.id
					  AND (g.score_a IS NULL OR g.score_b IS NULL)
				))
		  )
		ORDER BY t.event_date ASC, t.created_at ASC`)
	if err != nil {
		return 0, err
	}
	defer rows.Close()

		ingested := 0
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return ingested, err
		}
		// Finalisasi dulu (gate extractTournamentMatches: rating_sources.finalized),
		// baru ingest. Idempotent: SetSourceFinalized pakai ON CONFLICT.
		if err := s.SetSourceFinalized(ctx, id, true); err != nil {
			if s.logger != nil {
				s.logger.Warn("auto-ingest turnamen: finalisasi gagal", "tournament", id, "error", err)
			}
			continue
		}
		// Observabilitas: laporkan bila ada match berskor kosong. Kandidat
		// sudah disaring "semua berskor", jadi ini hanya muncul untuk kasus
		// tak terduga (mis. data berubah antara query kandidat dan ingest).
		if s.logger != nil {
			if n, err := s.CountUnscoredTournamentMatches(ctx, id); err == nil && n > 0 {
				s.logger.Warn("turnamen di-finalisasi dengan match berskor kosong",
					"tournament", id, "unscored", n)
			}
		}
		res, err := s.IngestTournament(ctx, id)
		if err != nil {
			// Jangan block turnamen lain — sama seperti sesi.
			if s.logger != nil {
				s.logger.Warn("auto-ingest turnamen: dilewati", "tournament", id, "error", err)
			}
			continue
		}
		if s.logger != nil {
			s.logger.Info("auto-ingest turnamen", "tournament", id, "processed", res.Processed)
		}
		// PENTING: hanya hitung kalau ADA yang ter-proses.
		// Turnamen yang semua matchnya ter-gate (mis. tanpa pemain terdaftar)
		// atau di luar season_start menghasilkan Processed=0 tetapi TETAP
		// menulis rating_sources (fingerprint terisi) -> tidak akan pernah
		// dicoba lagi. Laporkan supaya tidak hilang tanpa jejak.
		if res.Processed == 0 {
			if s.logger != nil {
				s.logger.Warn("auto-ingest turnamen: tidak ada match ter-proses",
					"tournament", id, "skipped", len(res.Skipped))
			}
			continue
		}
		ingested++
	}
	return ingested, rows.Err()
}

// CountUnscoredTournamentMatches — jumlah match/partai yang belum berskor pada
// sebuah turnamen. Dipakai hanya untuk observabilitas (log), bukan gate.
func (s *SessionStore) CountUnscoredTournamentMatches(ctx context.Context, sourceID string) (int, error) {
	var n int
	err := s.pool.QueryRow(ctx, `
		SELECT (
			SELECT count(*) FROM `+s.schema+`.tournament_matches tm
			JOIN `+s.schema+`.tournaments t ON t.id = tm.tournament_id
			WHERE t.share_code = $1 AND (tm.score_a IS NULL OR tm.score_b IS NULL)
		) + (
			SELECT count(*) FROM `+s.schema+`.tournament_team_match_games g
			JOIN `+s.schema+`.tournament_team_matches m ON m.id = g.team_match_id
			JOIN `+s.schema+`.tournaments t ON t.id = m.tournament_id
			WHERE t.share_code = $1 AND (g.score_a IS NULL OR g.score_b IS NULL)
		)`, sourceID).Scan(&n)
	if err != nil && err != pgx.ErrNoRows {
		return 0, fmt.Errorf("count unscored: %w", err)
	}
	return n, nil
}
