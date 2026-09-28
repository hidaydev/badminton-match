package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
)

// ── Season (RATING_TIERING_REVAMP §2.5.7-2.5.8) ───────────────────────────

// CloseAndStartSeason — tutup musim berjalan (arsip standings beku) + mulai
// musim baru dari startDate. Alur:
//  1. Snapshot final standings musim berjalan → season_player_snapshots
//  2. Tutup musim (end_date = startDate - 1)
//  3. Buat musim baru (auto "Season YYYY-N")
//  4. season_start config = startDate
//  5. Invalidasi fingerprint semua source (re-ingest wajib memproses ulang)
//  6. RebuildAll → Glicko musim baru mulai dari mid kelas, hanya events ≥ startDate
//
// PENTING: events musim lama TIDAK dihapus. History harus awet — ranking poin
// memakai window bergulir (12 minggu) yang membaca events lintas musim, dan
// menghapusnya membuat window mustahil dihitung. Glicko tetap "musim-scoped"
// karena rebuildAll hanya memutar events ≥ season_start, bukan karena
// penghapusan.
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
	var openStart string
	err = tx.QueryRow(ctx, `
		SELECT id::text, start_date::text FROM `+s.schema+`.rating_seasons
		WHERE end_date IS NULL ORDER BY start_date DESC LIMIT 1`).Scan(&seasonID, &openStart)
	if err == nil && openStart == startDate {
		// Musim dengan start_date sama sudah terbuka → ini RETRY setelah commit
		// sebelumnya sukses tapi RebuildAll gagal. Jangan arsip + buat musim baru
		// (akan menduplikasi musim). Cukup repair dengan rebuild.
		_ = tx.Rollback(ctx)
		if s.logger != nil {
			s.logger.Warn("close season: retry terdeteksi, rebuild ulang", "season", seasonID, "start_date", startDate)
		}
		if _, rErr := s.RebuildAll(ctx); rErr != nil {
			return "", rErr
		}
		return seasonID, nil
	}
	if err == nil {
		if _, err := tx.Exec(ctx, `
			INSERT INTO `+s.schema+`.season_player_snapshots
				(season_id, player_id, player_name, rating, rd, peak, class, games, wins, losses)
			SELECT $1::uuid, rp.player_id, p.canonical_name, rp.rating, rp.rd, rp.peak_rating,
			       p.tier, rp.games_played, rp.wins, rp.losses
			FROM `+s.schema+`.rating_players rp
			JOIN `+s.schema+`.players p ON p.id = rp.player_id`,
			seasonID); err != nil {
			return "", err
		}
		// Segel benih musim berikutnya: pemain yang PUNYA riwayat (≥1 game)
		// memakai rating terakhirnya sebagai titik awal, dengan RD ditumbuhkan
		// sesuai lama jeda. Pemain 0-game dibiarkan tanpa benih supaya musim
		// baru memperlakukannya sebagai pemain baru (mid kelas).
		// Nilai ini stabil: rebuildAll membacanya, bukan rating hasil rebuild.
		if err := s.sealSeasonSeeds(ctx, tx, false); err != nil {
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
	// Tidak ada musim terbuka: tetap segel benih dari state pemain saat ini.
	// Kalau ini dilewati, pemain ber-riwayat tidak punya seed_* dan saat musim
	// berikutnya di-rebuild mereka akan terlempar ke mid kelas — persis bug yang
	// ingin dicegah oleh benih. Terjadi pada DB baru / yang di-reset.
	if err != nil && errors.Is(err, pgx.ErrNoRows) {
		if err := s.sealSeasonSeeds(ctx, tx, true); err != nil {
			return "", err
		}
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
	tag, err := tx.Exec(ctx, `
		UPDATE `+s.schema+`.rating_config SET value = to_jsonb($1::text) WHERE key = 'season_start'`,
		startDate)
	if err != nil {
		return "", err
	}
	if tag.RowsAffected() == 0 {
		// Jangan lanjut delete events kalau config row hilang — gating musim
		// (subquery AutoIngestLockedSessions) jadi tidak konsisten.
		return "", fmt.Errorf("rating: season_start config row missing")
	}

	// 5. Invalidasi fingerprint semua source — re-ingest (post-season) wajib
	// memproses ulang. rating_players di-reset total oleh RebuildAll, jadi
	// state harus direkonstruksi dari events; fingerprint lama akan membuat
	// re-ingest jadi no-op.
	// NOTE: events musim lama SENGAJA tidak dihapus (lihat doc komentar atas).
	if _, err := tx.Exec(ctx, `UPDATE `+s.schema+`.rating_sources SET fingerprint = ''`); err != nil {
		return "", err
	}

	if err := tx.Commit(ctx); err != nil {
		return "", err
	}

	// 6. RebuildAll — Glicko musim baru mulai dari mid kelas, hanya events
	// ≥ startDate (season_start sudah digeser di langkah 4).
	if _, err := s.RebuildAll(ctx); err != nil {
		return "", err
	}

	return newID, nil
}

// sealSeasonSeeds — segel benih musim berikutnya dari state musim yang berakhir.
//
// Pemain dengan riwayat (games_played > 0) → seed = rating terakhir, seed_rd =
// RD yang sudah ditumbuhkan sesuai lama jeda (memakai domain.GrowRD yang sama
// dengan GrowthRD lain). Pemain 0-game tidak disegel: musim baru memperlakukan
// mereka sebagai pemain baru (mid kelas).
//
// Hanya dijalankan sekali per musim (CloseAndStartSeason). rebuildAll hanya
// MEMBACA seed ini, sehingga hasil rebuild selalu sama.
// sealSeasonSeeds — segel benih musim BERIKUTNYA dari state pemain saat ini.
// Parameter onlyMissing membatasi pada pemain yang belum punya benih.
//
// Benih disegel sekali per musim: rebuildAll membacanya, bukan rating hasil
// rebuild. Kalau benih diambil dari rating saat ini berulang kali, rebuild
// menjadi tidak idempotent (terukur: 1495 -> 1525 -> 1554).
func (s *SessionStore) sealSeasonSeeds(ctx context.Context, tx pgx.Tx, onlyMissing bool) error {
	cfg, err := s.LoadRatingConfig(ctx, false)
	if err != nil {
		return err
	}
	filter := ""
	if onlyMissing {
		filter = " AND seed_rating IS NULL"
	}
	rows, err := tx.Query(ctx, `
		SELECT player_id::text, rating, rd, coalesce(last_played_at::text, '')
		FROM `+s.schema+`.rating_players
		WHERE games_played > 0`+filter)
	if err != nil {
		return err
	}
	type seeded struct {
		id      string
		rating  float64
		rd      float64
		idleDay int
	}
	batch := []seeded{}
	for rows.Next() {
		var id, lastPlayed string
		var rating, rd float64
		if err := rows.Scan(&id, &rating, &rd, &lastPlayed); err != nil {
			rows.Close()
			return err
		}
		idleDays := 0
		if lastPlayed != "" {
			if last, perr := time.Parse("2006-01-02", lastPlayed); perr == nil {
				idleDays = int(time.Since(last).Hours() / 24)
			}
		}
		batch = append(batch, seeded{id: id, rating: rating, rd: rd, idleDay: idleDays})
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	for _, b := range batch {
		seedRD := domain.GrowRD(b.rd, b.idleDay, cfg.Params)
		if _, err := tx.Exec(ctx, `
			UPDATE `+s.schema+`.rating_players
			SET seed_rating = $2, seed_rd = $3, seed_set_at = now()
			WHERE player_id = $1::uuid`,
			b.id, b.rating, seedRD); err != nil {
			return err
		}
	}
	return nil
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
	Name        string  `json:"name"`
	Rating      float64 `json:"rating"`
	RD          float64 `json:"rd"`
	Peak        float64 `json:"peak"`
	Tier        string  `json:"tier"`         // tier saat arsip (players.tier sticky)
	TierDisplay string  `json:"tier_display"` // = derived dari rating arsip (badge murni)
	Games       int     `json:"games"`
	Wins        int     `json:"wins"`
	Losses      int     `json:"losses"`
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
		if err := rows.Scan(&r.Name, &r.Rating, &r.RD, &r.Peak, &r.Tier, &r.Games, &r.Wins, &r.Losses); err != nil {
			return nil, err
		}
		r.TierDisplay = cfg.TierForRating(r.Rating)
		out = append(out, r)
	}
	return out, rows.Err()
}
