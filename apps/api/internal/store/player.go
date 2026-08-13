package store

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"
)

// PlayerStore — registry pemain + statistik (read-path di Go).
type PlayerStore struct {
	pool *pgxpool.Pool
}

// NewPlayerStore — buat PlayerStore dengan pool koneksi.
func NewPlayerStore(pool *pgxpool.Pool) *PlayerStore {
	return &PlayerStore{pool: pool}
}

// PlayerSummary — baris dari list_players (read-path port bm.list_players).
type PlayerSummary struct {
	Name   string `json:"name"`
	Gender string `json:"gender"`
	Tier   int    `json:"tier"`
}

// List — daftar pemain terdaftar (port bm.list_players): gender/tier diambil
// dari penampilan TERAKHIR (session_date desc, updated_at desc), urut by lower(name).
func (s *PlayerStore) List(ctx context.Context) ([]PlayerSummary, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT ra.canonical_name, ra.gender, ra.tier
		FROM (
			SELECT p.id, p.canonical_name, sp.gender, sp.tier,
			       row_number() OVER (
				       PARTITION BY p.id
				       ORDER BY s.session_date DESC, sp.updated_at DESC, sp.internal_id DESC
			       ) AS rn
			FROM players p
			JOIN session_players sp ON sp.player_id = p.id
			JOIN sessions s ON s.id = sp.session_id
		) ra
		WHERE ra.rn = 1
		ORDER BY lower(ra.canonical_name)`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]PlayerSummary, 0)
	for rows.Next() {
		var p PlayerSummary
		if err := rows.Scan(&p.Name, &p.Gender, &p.Tier); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// Register — registry pemain (register_player SQL). Fungsi SQL TETAP dipakai:
// resolve_tournament_player → publish_tournament (masih SQL) bergantung padanya.
func (s *PlayerStore) Register(ctx context.Context, name, canonicalName string) (string, error) {
	var id string
	err := s.pool.QueryRow(ctx,
		`SELECT register_player($1, $2)`,
		name, canonicalName,
	).Scan(&id)
	if err != nil {
		return "", err
	}
	return id, nil
}

// Stats — statistik karier pemain (port bm.get_player_stats_compat) → JSON.
// Pemain tidak dikenal → statistik kosong dengan `name` = nama yang dicari.
func (s *PlayerStore) Stats(ctx context.Context, name string) ([]byte, error) {
	return computePlayerStats(ctx, s.pool, name)
}
