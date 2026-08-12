package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TournamentStore — akses tournament via fungsi bm_dev yang tervalidasi.
type TournamentStore struct {
	pool *pgxpool.Pool
}

func NewTournamentStore(pool *pgxpool.Pool) *TournamentStore {
	return &TournamentStore{pool: pool}
}

// Load — get_tournament(id) → snapshot ter-decode.
func (s *TournamentStore) Load(ctx context.Context, id string) (*domain.TournamentSnapshot, error) {
	var raw []byte
	err := s.pool.QueryRow(ctx, `SELECT get_tournament($1)`, id).Scan(&raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if raw == nil {
		return nil, ErrNotFound
	}
	snap := &domain.TournamentSnapshot{}
	if err := json.Unmarshal(raw, snap); err != nil {
		return nil, fmt.Errorf("decode tournament: %w", err)
	}
	return snap, nil
}

// Save — publish_tournament(id, snapshot) → snapshot hasil publish.
func (s *TournamentStore) Save(ctx context.Context, id string, snap *domain.TournamentSnapshot) (*domain.TournamentSnapshot, error) {
	body, err := json.Marshal(snap)
	if err != nil {
		return nil, err
	}
	var raw []byte
	err = s.pool.QueryRow(ctx,
		`SELECT publish_tournament($1, $2::jsonb)`,
		id, string(body),
	).Scan(&raw)
	if err != nil {
		return nil, err
	}
	out := &domain.TournamentSnapshot{}
	if err := json.Unmarshal(raw, out); err != nil {
		return nil, fmt.Errorf("decode published tournament: %w", err)
	}
	return out, nil
}
