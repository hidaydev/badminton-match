package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// ── Season (RATING_TIERING_REVAMP §2.5.7-2.5.8) ───────────────────────────

// CloseAndStartSeason — tutup musim berjalan (arsip standings beku) + mulai
// musim baru dari startDate. Alur:
//  1. Snapshot final standings musim berjalan → season_player_snapshots
//  2. Tutup musim (end_date = startDate - 1)
//  3. Buat musim baru (auto "Season YYYY-N")
//  4. season_start config = startDate
//  5. Hapus events < startDate (musim lama tidak dihitung)
//  6. RebuildAll → semua pemain forming ulang dari mid kelas
func (s *SessionStore) CloseAndStartSeason(ctx context.Context, startDate string) (string, error) {
	start, err := time.Parse("2006-01-02", startDate)
	if err != nil {
		return "", fmt.Errorf("rating: invalid startDate %q", startDate)
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		return "", err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`,
		s.schema+":ratings_ingest"); err != nil {
		return "", err
	}

	// 1-2. Arsip musim terbuka (jika ada)
	var seasonID string
	err = tx.QueryRow(ctx, `
		SELECT id::text FROM `+s.schema+`.rating_seasons
		WHERE end_date IS NULL ORDER BY start_date DESC LIMIT 1`).Scan(&seasonID)
	if err == nil {
		if _, err := tx.Exec(ctx, `
			INSERT INTO `+s.schema+`.season_player_snapshots
				(season_id, player_id, player_name, rating, rd, peak, class, games, wins, losses)
			SELECT $1::uuid, rp.player_id, p.canonical_name, rp.rating, rp.rd, rp.peak_rating,
			       rp.class, rp.games_played, rp.wins, rp.losses
			FROM `+s.schema+`.rating_players rp
			JOIN `+s.schema+`.players p ON p.id = rp.player_id`,
			seasonID); err != nil {
			return "", err
		}
		if _, err := tx.Exec(ctx, `
			UPDATE `+s.schema+`.rating_seasons
			SET end_date = $1::date, closed_at = now()
			WHERE id = $2::uuid`,
			start.AddDate(0, 0, -1).Format("2006-01-02"), seasonID); err != nil {
			return "", err
		}
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return "", err
	}

	// 3. Musim baru — auto "Season YYYY-N"
	newName := autoSeasonName(ctx, tx, s.schema, start.Year())
	var newID string
	if err := tx.QueryRow(ctx, `
		INSERT INTO `+s.schema+`.rating_seasons (name, start_date)
		VALUES ($1, $2::date) RETURNING id::text`,
		newName, startDate).Scan(&newID); err != nil {
		return "", err
	}

	// 4. season_start config
	if _, err := tx.Exec(ctx, `
		UPDATE `+s.schema+`.rating_config SET value = to_jsonb($1::text) WHERE key = 'season_start'`,
		startDate); err != nil {
		return "", err
	}

	// 5. Hapus events musim lama (deltas cascade)
	if _, err := tx.Exec(ctx, `DELETE FROM `+s.schema+`.rating_events WHERE date < $1::date`, startDate); err != nil {
		return "", err
	}
	// Invalidasi fingerprint semua source — re-ingest (post-season) wajib
	// memproses ulang (events sudah dihapus; fingerprint lama membuat no-op).
	if _, err := tx.Exec(ctx, `UPDATE `+s.schema+`.rating_sources SET fingerprint = ''`); err != nil {
		return "", err
	}

	if err := tx.Commit(ctx); err != nil {
		return "", err
	}

	// 6. RebuildAll (forming ulang dari mid kelas, events ≥ startDate)
	if _, err := s.RebuildAll(ctx); err != nil {
		return "", err
	}

	return newID, nil
}

// autoSeasonName — "Season 2026-1", "Season 2026-2", dst.
func autoSeasonName(ctx context.Context, tx pgx.Tx, schema string, year int) string {
	var n int
	_ = tx.QueryRow(ctx, `
		SELECT count(*) FROM `+schema+`.rating_seasons WHERE start_date >= $1::date`,
		fmt.Sprintf("%04d-01-01", year)).Scan(&n)
	return fmt.Sprintf("Season %d-%d", year, n+1)
}

// SeasonRow — baris daftar musim.
type SeasonRow struct {
	ID        string  `json:"id"`
	Name      string  `json:"name"`
	StartDate string  `json:"start_date"`
	EndDate   *string `json:"end_date"`
	Open      bool    `json:"open"`
}

// ListSeasons — daftar musim (terbuka dulu, lalu tertutup desc).
func (s *SessionStore) ListSeasons(ctx context.Context) ([]SeasonRow, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT id::text, name, start_date::text, end_date::text
		FROM `+s.schema+`.rating_seasons
		ORDER BY (end_date IS NULL) DESC, start_date DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []SeasonRow{}
	for rows.Next() {
		var r SeasonRow
		var end *string
		if err := rows.Scan(&r.ID, &r.Name, &r.StartDate, &end); err != nil {
			return nil, err
		}
		r.EndDate = end
		r.Open = end == nil
		out = append(out, r)
	}
	return out, rows.Err()
}

// SeasonStandingRow — baris standings beku.
type SeasonStandingRow struct {
	Name         string  `json:"name"`
	Rating       float64 `json:"rating"`
	RD           float64 `json:"rd"`
	Peak         float64 `json:"peak"`
	Class        string  `json:"class"`
	ClassDisplay string  `json:"class_display"`
	Games        int     `json:"games"`
	Wins         int     `json:"wins"`
	Losses       int     `json:"losses"`
}

// SeasonStandings — standings beku sebuah musim (urut rating desc).
func (s *SessionStore) SeasonStandings(ctx context.Context, seasonID string) ([]SeasonStandingRow, error) {
	cfg, err := s.LoadRatingConfig(ctx, false)
	if err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT player_name, rating, rd, peak, coalesce(class, ''), games, wins, losses
		FROM `+s.schema+`.season_player_snapshots
		WHERE season_id = $1::uuid
		ORDER BY rating DESC, player_name ASC`, seasonID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []SeasonStandingRow{}
	for rows.Next() {
		var r SeasonStandingRow
		if err := rows.Scan(&r.Name, &r.Rating, &r.RD, &r.Peak, &r.Class, &r.Games, &r.Wins, &r.Losses); err != nil {
			return nil, err
		}
		r.ClassDisplay = cfg.DisplayClass(r.Rating, r.Class)
		out = append(out, r)
	}
	return out, rows.Err()
}
