package store

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"
)

// PlayerStore — registry pemain + statistik.
type PlayerStore struct {
	pool *pgxpool.Pool
}

func NewPlayerStore(pool *pgxpool.Pool) *PlayerStore {
	return &PlayerStore{pool: pool}
}

// PlayerSummary — baris dari list_players().
type PlayerSummary struct {
	Name   string `json:"name"`
	Gender string `json:"gender"`
	Tier   int    `json:"tier"`
}

func (s *PlayerStore) List(ctx context.Context) ([]PlayerSummary, error) {
	rows, err := s.pool.Query(ctx, `SELECT name, gender, tier FROM list_players()`)
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

// Register — register_player(name, canonicalName) → uuid.
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

// Stats — get_player_stats(name) → raw JSON (shape dikontrol fungsi).
// Player yang tidak terdaftar → ErrNotFound.
func (s *PlayerStore) Stats(ctx context.Context, name string) ([]byte, error) {
	var raw []byte
	err := s.pool.QueryRow(ctx, `SELECT get_player_stats($1)`, name).Scan(&raw)
	if err != nil {
		return nil, err
	}
	if raw == nil {
		return nil, ErrNotFound
	}
	return raw, nil
}

// EnsurePlayerRegistered — daftarkan jika belum (idempotent), dipakai saat
// create session supaya validasi resolve player lolos.
func (s *PlayerStore) EnsurePlayerRegistered(ctx context.Context, name string) error {
	if _, err := s.Register(ctx, name, name); err != nil {
		return err
	}
	return nil
}
