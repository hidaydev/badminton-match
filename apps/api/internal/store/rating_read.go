package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// ── Rating read path (RATING_ENGINE_DESIGN.md §6) ─────────────────────────

// RatingHistoryRow — satu baris riwayat pertandingan pemain.
//
// Sejak Glicko dipensiunkan (2026-09-29) baris ini TIDAK lagi memuat angka
// rating (delta/expected/movm/new_rating): semuanya berhenti bermakna. Yang
// tersisa adalah fakta pertandingan — tanggal, lawan, skor, hasil.
type RatingHistoryRow struct {
	Date      string   `json:"date"`
	Title     string   `json:"title"`
	GameRef   string   `json:"game_ref"`
	Outcome   string   `json:"outcome"`
	ScoreA    int      `json:"score_a"`
	ScoreB    int      `json:"score_b"`
	Teammates []string `json:"teammates"`
	Opponents []string `json:"opponents"`
}

// RatingPlayerDetail — detail pemain + riwayat pertandingan.
//
// Sejak Glicko dipensiunkan (2026-09-29): rating/rd/peak/tier_derived tidak
// lagi disajikan — tidak ada mesin yang menghitungnya. Tier yang tersisa
// adalah players.tier (sticky), satu-satunya sumber kelas pemain.
type RatingPlayerDetail struct {
	Name    string             `json:"name"`
	Tier    string             `json:"tier"`
	Games   int                `json:"games"`
	Wins    int                `json:"wins"`
	Losses  int                `json:"losses"`
	History []RatingHistoryRow `json:"history"`
}

// RatingPlayer — detail pemain (by player_id uuid).
//
// games/wins/losses diambil dari rating_players (bookkeeping yang tetap
// dipelihara ingest), tier dari players.tier (sticky). Tidak ada angka
// rating yang disajikan.
func (s *SessionStore) RatingPlayer(ctx context.Context, playerID string) (*RatingPlayerDetail, error) {
	var d RatingPlayerDetail
	err := s.pool.QueryRow(ctx, `
		SELECT p.canonical_name, coalesce(p.tier, ''),
		       coalesce(rp.games_played, 0), coalesce(rp.wins, 0), coalesce(rp.losses, 0)
		FROM `+s.schema+`.players p
		LEFT JOIN `+s.schema+`.rating_players rp ON rp.player_id = p.id
		WHERE p.id = $1::uuid`, playerID).
		Scan(&d.Name, &d.Tier, &d.Games, &d.Wins, &d.Losses)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
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
		       re.score_a, re.score_b,
		       (SELECT COALESCE(array_agg(p.canonical_name ORDER BY p.canonical_name), '{}')
		        FROM `+s.schema+`.rating_deltas rd2
		        JOIN `+s.schema+`.players p ON p.id = rd2.player_id
		        WHERE rd2.event_id = re.id AND rd2.team = rd.team AND rd2.player_id != $1::uuid),
		       (SELECT COALESCE(array_agg(p.canonical_name ORDER BY p.canonical_name), '{}')
		        FROM `+s.schema+`.rating_deltas rd3
		        JOIN `+s.schema+`.players p ON p.id = rd3.player_id
		        WHERE rd3.event_id = re.id AND rd3.team != rd.team)
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
			&h.ScoreA, &h.ScoreB,
			&h.Teammates, &h.Opponents); err != nil {
			return nil, err
		}
		out = append(out, h)
	}
	return out, rows.Err()
}

// RatingSource — baris rating_sources.
type RatingSource struct {
	SourceID   string    `json:"source_id"`
	SourceName string    `json:"source_name"` // resolved name (session title or tournament name)
	SourceKind string    `json:"source_kind"`
	Finalized  bool      `json:"finalized"`
	IngestedAt time.Time `json:"ingested_at"`
	EventCount int       `json:"event_count"`
}

// ListRatingSources — daftar source + jumlah events + resolved name.
func (s *SessionStore) ListRatingSources(ctx context.Context) ([]RatingSource, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT rs.source_id,
		       COALESCE(ses.title, t.name, rs.source_id) AS source_name,
		       rs.source_kind, rs.finalized, rs.ingested_at,
		       (SELECT count(*) FROM `+s.schema+`.rating_events re WHERE re.source_id = rs.source_id)
		FROM `+s.schema+`.rating_sources rs
		LEFT JOIN `+s.schema+`.sessions ses ON ses.share_code = rs.source_id
		LEFT JOIN `+s.schema+`.tournaments t ON t.share_code = rs.source_id
		ORDER BY rs.ingested_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []RatingSource{}
	for rows.Next() {
		var s2 RatingSource
		if err := rows.Scan(&s2.SourceID, &s2.SourceName, &s2.SourceKind, &s2.Finalized, &s2.IngestedAt, &s2.EventCount); err != nil {
			return nil, err
		}
		out = append(out, s2)
	}
	return out, rows.Err()
}
