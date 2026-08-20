package store

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
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
	PlayerID  string `json:"playerId"`
	Name      string `json:"name"`
	Gender    string `json:"gender"`
	Tier      int    `json:"tier"`      // tier penampilan terakhir (legacy)
	TierInduk string `json:"tierInduk"` // tier induk STICKY (players.tier) — admin
}

// List — daftar pemain terdaftar (port bm.list_players): gender diambil dari
// players table (canonical), tier dari penampilan TERAKHIR, urut by lower(name).
func (s *PlayerStore) List(ctx context.Context) ([]PlayerSummary, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT p.id::text, p.canonical_name, p.gender, coalesce(sp.tier, 0), coalesce(p2.tier, '')
		FROM players p
		LEFT JOIN (
			SELECT sp.player_id, sp.tier,
			       row_number() OVER (
				       PARTITION BY sp.player_id
				       ORDER BY s.session_date DESC, sp.updated_at DESC, sp.internal_id DESC
			       ) AS rn
			FROM session_players sp
			JOIN sessions s ON s.id = sp.session_id
			WHERE sp.player_id IS NOT NULL
		) sp ON sp.player_id = p.id AND sp.rn = 1
		LEFT JOIN players p2 ON p2.id = p.id
		ORDER BY lower(p.canonical_name)`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]PlayerSummary, 0)
	for rows.Next() {
		var p PlayerSummary
		if err := rows.Scan(&p.PlayerID, &p.Name, &p.Gender, &p.Tier, &p.TierInduk); err != nil {
			return nil, err
		}
		// Read-time filter placeholder (ABSENT_TBD_PLAYERS_DESIGN.md §5.5) —
		// pemain legacy "free*" disembunyikan dari daftar tanpa dihapus.
		if domain.IsPlaceholderName(p.Name) {
			continue
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// Register — registry pemain (port bm.register_player): idempotent dan
// TOCTOU-safe (re-query alias setelah INSERT ON CONFLICT DO NOTHING).
func (s *PlayerStore) Register(ctx context.Context, name, canonicalName, gender string) (string, error) {
	if canonicalName == "" {
		canonicalName = name
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	pid, err := registerPlayerInTx(ctx, tx, name, canonicalName, gender)
	if err != nil {
		return "", err
	}
	if err := tx.Commit(ctx); err != nil {
		return "", err
	}
	return pid, nil
}

// Stats — statistik karier pemain (port bm.get_player_stats_compat) → JSON.
// Pemain tidak dikenal → statistik kosong dengan `name` = nama yang dicari.
func (s *PlayerStore) Stats(ctx context.Context, name string) ([]byte, error) {
	return computePlayerStats(ctx, s.pool, name)
}

// RenamePlayer — rename canonical player (admin, BACKLOG_ANALYSIS A5).
// Anti-collision: nama baru yang sudah resolve ke player LAIN ditolak.
// Alias nama lama disimpan → referensi historis (snapshot sesi, stats)
// tetap resolve. Rating leaderboard (player_id) tidak terpengaruh.
func (s *PlayerStore) RenamePlayer(ctx context.Context, playerID, newName string) error {
	newNorm := domain.NormalizePlayerName(newName)
	if newNorm == "" {
		return fmt.Errorf("%w: player name must not be blank", ErrValidation)
	}
	if domain.IsPlaceholderName(newName) {
		return fmt.Errorf("%w: cannot rename to a placeholder name", ErrValidation)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var oldCanonical string
	if err := tx.QueryRow(ctx,
		`SELECT canonical_name FROM players WHERE id = $1::uuid`, playerID).Scan(&oldCanonical); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("%w: player not found", ErrNotFound)
		}
		return err
	}
	// Anti-collision: nama baru resolve ke pemain LAIN?
	var owner string
	err = tx.QueryRow(ctx, `
		SELECT p.id::text FROM player_aliases pa
		JOIN players p ON p.id = pa.player_id
		WHERE pa.alias_name = $1 LIMIT 1`, newNorm).Scan(&owner)
	if err == nil && owner != playerID {
		return fmt.Errorf("%w: name is already taken by another player", ErrValidation)
	}
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return err
	}

	if _, err := tx.Exec(ctx, `
		UPDATE players SET canonical_name = $2, updated_at = now() WHERE id = $1::uuid`,
		playerID, strings.TrimSpace(newName)); err != nil {
		return err
	}
	// Alias nama lama → referensi historis tetap resolve.
	oldNorm := domain.NormalizePlayerName(oldCanonical)
	if oldNorm != "" && oldNorm != newNorm {
		if _, err := tx.Exec(ctx, `
			INSERT INTO player_aliases (player_id, alias_name) VALUES ($1, $2)
			ON CONFLICT DO NOTHING`, playerID, oldNorm); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
