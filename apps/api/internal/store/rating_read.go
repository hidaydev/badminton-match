package store

import (
	"context"
	"errors"
	"time"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
)

// ── Rating read path (RATING_ENGINE_DESIGN.md §6) ─────────────────────────

// LeaderboardRow — baris leaderboard.
type LeaderboardRow struct {
	PlayerID    string  `json:"player_id"`
	Name        string  `json:"name"`
	Rating      float64 `json:"rating"`
	RD          float64 `json:"rd"`
	Tier        int     `json:"tier"`
	Peak        float64 `json:"peak"`
	Games       int     `json:"games"`
	Trend       float64 `json:"trend"`
	Provisional bool    `json:"provisional"`
}

// RatingLeaderboard — leaderboard rating, urut rating desc. `active` =
// games_played > 0 (dan, opsional, main dalam 90 hari terakhir).
func (s *SessionStore) RatingLeaderboard(ctx context.Context, active bool, limit, offset int) (int, []LeaderboardRow, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}

	where := ""
	if active {
		where = ` WHERE rp.games_played > 0 AND rp.last_played_at >= now() - interval '90 days'`
	}

	var total int
	if err := s.pool.QueryRow(ctx,
		`SELECT count(*) FROM `+s.schema+`.rating_players rp`+where).Scan(&total); err != nil {
		return 0, nil, err
	}

	rows, err := s.pool.Query(ctx, `
		SELECT rp.player_id::text, p.canonical_name, rp.rating, rp.rd, rp.peak_rating, rp.games_played,
		       coalesce(tr.delta, 0)
		FROM `+s.schema+`.rating_players rp
		JOIN `+s.schema+`.players p ON p.id = rp.player_id
		LEFT JOIN LATERAL (
			SELECT rd.delta
			FROM `+s.schema+`.rating_deltas rd
			JOIN `+s.schema+`.rating_events re ON re.id = rd.event_id
			WHERE rd.player_id = rp.player_id
			ORDER BY re.date DESC, re.created_at DESC, re.source_id DESC, re.game_order DESC
			LIMIT 1
		) tr ON true`+where+`
		ORDER BY rp.rating DESC, p.canonical_name ASC
		LIMIT $1 OFFSET $2`, limit, offset)
	if err != nil {
		return 0, nil, err
	}
	defer rows.Close()

	out := []LeaderboardRow{}
	for rows.Next() {
		var r LeaderboardRow
		if err := rows.Scan(&r.PlayerID, &r.Name, &r.Rating, &r.RD, &r.Peak, &r.Games, &r.Trend); err != nil {
			return 0, nil, err
		}
		r.Tier = domain.TierForRating(r.Rating)
		r.Provisional = domain.Provisional(r.RD)
		out = append(out, r)
	}
	return total, out, rows.Err()
}

// RatingHistoryRow — satu baris history pemain.
type RatingHistoryRow struct {
	Date      string  `json:"date"`
	Title     string  `json:"title"`
	GameRef   string  `json:"game_ref"`
	Outcome   string  `json:"outcome"`
	Delta     float64 `json:"delta"`
	Expected  float64 `json:"expected"`
	Movm      float64 `json:"movm"`
	ScoreA    int     `json:"score_a"`
	ScoreB    int     `json:"score_b"`
	NewRating float64 `json:"new_rating"`
}

// RatingPlayerDetail — detail pemain + history.
type RatingPlayerDetail struct {
	Name    string             `json:"name"`
	Rating  float64            `json:"rating"`
	RD      float64            `json:"rd"`
	Tier    int                `json:"tier"`
	Peak    float64            `json:"peak"`
	Games   int                `json:"games"`
	Wins    int                `json:"wins"`
	Losses  int                `json:"losses"`
	History []RatingHistoryRow `json:"history"`
}

// RatingPlayer — detail pemain (by player_id uuid).
func (s *SessionStore) RatingPlayer(ctx context.Context, playerID string) (*RatingPlayerDetail, error) {
	var d RatingPlayerDetail
	err := s.pool.QueryRow(ctx, `
		SELECT p.canonical_name, rp.rating, rp.rd, rp.peak_rating, rp.games_played,
		       rp.wins, rp.losses
		FROM `+s.schema+`.rating_players rp
		JOIN `+s.schema+`.players p ON p.id = rp.player_id
		WHERE rp.player_id = $1::uuid`, playerID).
		Scan(&d.Name, &d.Rating, &d.RD, &d.Peak, &d.Games, &d.Wins, &d.Losses)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	d.Tier = domain.TierForRating(d.Rating)
	d.History, err = s.RatingPlayerHistory(ctx, playerID, 200)
	if err != nil {
		return nil, err
	}
	return &d, nil
}

// RatingPlayerHistory — history rating pemain (desc by event date).
func (s *SessionStore) RatingPlayerHistory(ctx context.Context, playerID string, limit int) ([]RatingHistoryRow, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := s.pool.Query(ctx, `
		SELECT re.date::text, re.title, re.stable_game_id, rd.outcome,
		       rd.delta, rd.expected, rd.movm, re.score_a, re.score_b, rd.new_rating
		FROM `+s.schema+`.rating_deltas rd
		JOIN `+s.schema+`.rating_events re ON re.id = rd.event_id
		WHERE rd.player_id = $1::uuid
		ORDER BY re.date DESC, re.created_at DESC, re.source_id DESC, re.game_order DESC
		LIMIT $2`, playerID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []RatingHistoryRow{}
	for rows.Next() {
		var h RatingHistoryRow
		if err := rows.Scan(&h.Date, &h.Title, &h.GameRef, &h.Outcome,
			&h.Delta, &h.Expected, &h.Movm, &h.ScoreA, &h.ScoreB, &h.NewRating); err != nil {
			return nil, err
		}
		out = append(out, h)
	}
	return out, rows.Err()
}

// RatingSource — baris rating_sources.
type RatingSource struct {
	SourceID   string    `json:"source_id"`
	SourceKind string    `json:"source_kind"`
	Finalized  bool      `json:"finalized"`
	IngestedAt time.Time `json:"ingested_at"`
	EventCount int       `json:"event_count"`
}

// ListRatingSources — daftar source + jumlah events.
func (s *SessionStore) ListRatingSources(ctx context.Context) ([]RatingSource, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT rs.source_id, rs.source_kind, rs.finalized, rs.ingested_at,
		       (SELECT count(*) FROM `+s.schema+`.rating_events re WHERE re.source_id = rs.source_id)
		FROM `+s.schema+`.rating_sources rs
		ORDER BY rs.ingested_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []RatingSource{}
	for rows.Next() {
		var s2 RatingSource
		if err := rows.Scan(&s2.SourceID, &s2.SourceKind, &s2.Finalized, &s2.IngestedAt, &s2.EventCount); err != nil {
			return nil, err
		}
		out = append(out, s2)
	}
	return out, rows.Err()
}
