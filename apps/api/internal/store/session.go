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

var (
	ErrNotFound = errors.New("not found")
)

// SessionStore — akses session. Load/Save memakai fungsi bm_dev yang sudah
// tervalidasi (get_session/publish_session). Transform logic hidup di Go
// (internal/domain), migrasi bertahap dari fungsi SQL.
type SessionStore struct {
	pool *pgxpool.Pool
}

func NewSessionStore(pool *pgxpool.Pool) *SessionStore {
	return &SessionStore{pool: pool}
}

// Load — get_session(id) → snapshot ter-decode.
func (s *SessionStore) Load(ctx context.Context, id string) (*domain.CloudSnapshot, error) {
	var raw []byte
	err := s.pool.QueryRow(ctx, `SELECT get_session($1)`, id).Scan(&raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	// get_session mengembalikan NULL (bukan no-rows) saat sesi tak ada.
	if raw == nil {
		return nil, ErrNotFound
	}
	snap := &domain.CloudSnapshot{}
	if err := json.Unmarshal(raw, snap); err != nil {
		return nil, fmt.Errorf("decode snapshot: %w", err)
	}
	return snap, nil
}

// Save — publish_session(id, snapshot) → snapshot hasil publish (version baru).
func (s *SessionStore) Save(ctx context.Context, id string, snap *domain.CloudSnapshot) (*domain.CloudSnapshot, error) {
	body, err := json.Marshal(snap)
	if err != nil {
		return nil, err
	}
	var raw []byte
	err = s.pool.QueryRow(ctx,
		`SELECT publish_session($1, $2::jsonb)`,
		id, string(body),
	).Scan(&raw)
	if err != nil {
		return nil, err
	}
	out := &domain.CloudSnapshot{}
	if err := json.Unmarshal(raw, out); err != nil {
		return nil, fmt.Errorf("decode published snapshot: %w", err)
	}
	return out, nil
}

// Delete — delete_session(id).
func (s *SessionStore) Delete(ctx context.Context, id string) error {
	var raw []byte
	err := s.pool.QueryRow(ctx, `SELECT delete_session($1)`, id).Scan(&raw)
	if err != nil {
		return err
	}
	return nil
}

// RegisterPlayer — register_player(name, canonicalName) → uuid.
func (s *SessionStore) RegisterPlayer(ctx context.Context, name, canonicalName string) (string, error) {
	var id string
	err := s.pool.QueryRow(ctx,
		`SELECT register_player($1, $2)`,
		name, canonicalName,
	).Scan(&id)
	return id, err
}

// EnsurePlayersRegistered — daftarkan semua pemain (idempotent) sebelum
// publish pertama, supaya validasi resolve player di publish_session lolos.
func (s *SessionStore) EnsurePlayersRegistered(ctx context.Context, players []domain.Player) error {
	for _, p := range players {
		if _, err := s.RegisterPlayer(ctx, p.Name, p.Name); err != nil {
			return fmt.Errorf("register %q: %w", p.Name, err)
		}
	}
	return nil
}

// SessionMeta — baris dari list_sessions() (key JSON sama dengan kontrak RPC).
type SessionMeta struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Date        string `json:"date"`
	PlayerCount int    `json:"player_count"`
	TotalGames  int    `json:"total_games"`
	Locked      bool   `json:"locked"`
}

func (s *SessionStore) ListSessions(ctx context.Context) ([]SessionMeta, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id, title, date, player_count, total_games, locked FROM list_sessions()`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]SessionMeta, 0)
	for rows.Next() {
		var m SessionMeta
		if err := rows.Scan(&m.ID, &m.Title, &m.Date, &m.PlayerCount, &m.TotalGames, &m.Locked); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}
