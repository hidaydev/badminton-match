// Operasi admin: lock/delete/unlock, ensure players, list sessions.

package store

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
)

// LockPastDateDrafts — auto-lock draft sessions yang session_date-nya sudah
// lewat (WIB) — mirror aturan pastDate di Save(), tapi tanpa butuh PUT
// lanjutan. Dipanggil ticker sebelum AutoIngestLockedSessions supaya sesi yang
// skornya masuk via granular (tanpa publish PUT setelah tanggal lewat) tetap
// ter-lock dan rating-nya bisa di-ingest. Version +1 (satu bump, sama seperti
// granular auto-lock) — mutasi berikutnya ditolak oleh status locked sebelum
// version check, jadi FE tidak kena 40001.
func (s *SessionStore) LockPastDateDrafts(ctx context.Context) (int, error) {
	tag, err := s.pool.Exec(ctx, `
		UPDATE sessions
		SET status = 'locked', version = version + 1, updated_at = now()
		WHERE status = 'draft'
		  AND session_date < (SELECT (now() AT TIME ZONE 'Asia/Jakarta')::date)`)
	if err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}

// Delete — delete write-path (port bm.delete_session): tolak non-draft, lalu
// hapus baris sessions — child tables terhapus via ON DELETE CASCADE.
func (s *SessionStore) Delete(ctx context.Context, lookup string) error {
	if strings.TrimSpace(lookup) == "" {
		return fmt.Errorf("%w: session lookup must not be blank", ErrValidation)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var (
		rowID  string
		status string
	)
	err = tx.QueryRow(ctx, `
		SELECT s.id::text, s.status
		FROM sessions s
		WHERE s.share_code = $1 OR s.id::text = $1
		ORDER BY (s.share_code = $1) DESC
		LIMIT 1
		FOR UPDATE NOWAIT`, lookup).Scan(&rowID, &status)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return fmt.Errorf("%w: session not found: %s", ErrNotFound, lookup)
	case err != nil:
		if isLockNotAvailable(err) {
			return ErrContention
		}
		return err
	}
	if status != "draft" {
		return fmt.Errorf("%w: cannot delete a locked session; unlock it first", ErrLocked)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM sessions WHERE id = $1::uuid`, rowID); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Unlock — buka kunci session (port bm.unlock_session): status → 'draft',
// version +1. No-op (tanpa bump version) jika sudah draft. Tanpa syarat If-Match
// — mirror fungsi SQL admin yang digantikannya.
func (s *SessionStore) Unlock(ctx context.Context, id string) (*domain.CloudSnapshot, error) {
	if id = strings.TrimSpace(id); id == "" {
		return nil, fmt.Errorf("%w: session id must not be blank", ErrValidation)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var locked bool
	if err := tx.QueryRow(ctx,
		`SELECT pg_try_advisory_xact_lock(hashtextextended($1 || ':' || $2, 0))`,
		s.schema+".unlock_session", id,
	).Scan(&locked); err != nil {
		return nil, err
	}
	if !locked {
		return nil, ErrContention
	}

	var (
		rowID   string
		status  string
		version int
	)
	err = tx.QueryRow(ctx, `
		SELECT s.id::text, s.status, s.version
		FROM sessions s
		WHERE s.share_code = $1 OR s.id::text = $1
		ORDER BY (s.share_code = $1) DESC
		LIMIT 1
		FOR UPDATE NOWAIT`, id).Scan(&rowID, &status, &version)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return nil, ErrNotFound
	case err != nil:
		if isLockNotAvailable(err) {
			return nil, ErrContention
		}
		return nil, err
	}

	if status != "draft" {
		if _, err := tx.Exec(ctx, `
			UPDATE sessions SET status = 'draft', version = version + 1, updated_at = now()
			WHERE id = $1::uuid`, rowID); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out, err := s.Load(ctx, id)
	// Broadcast ke SSE watcher — tanpa ini client yang sedang membuka sesi
	// tidak dapat update status unlocked dan harus manual refresh (bug #2 RC-B).
	if err == nil && out != nil {
		s.Broadcast(id, out)
	}
	return out, err
}

// EnsurePlayersRegistered — daftarkan semua pemain (idempotent, TOCTOU-safe)
// sebelum publish, supaya validasi resolve player di write-path lolos.
// Satu transaksi untuk semua pemain (port bm.register_player — fungsi SQL
// sudah pensiun; lihat registerPlayerInTx).
func (s *SessionStore) EnsurePlayersRegistered(ctx context.Context, players []domain.Player) error {
	if len(players) == 0 {
		return nil
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()

	for _, p := range players {
		// Placeholder (free/tbd/dst — ABSENT_TBD_PLAYERS_DESIGN.md §5) tidak
		// diregistrasi ke players/aliases.
		if domain.IsPlaceholderName(p.Name) {
			continue
		}
		if _, err := registerPlayerInTx(ctx, tx, s.schema, p.Name, p.Name, p.Gender); err != nil {
			return fmt.Errorf("register %q: %w", p.Name, err)
		}
	}
	return tx.Commit(ctx)
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

// ListSessions — read-path (port bm.list_sessions): metadata semua session
// (share_code, title, date, player_count, total_games, locked).
func (s *SessionStore) ListSessions(ctx context.Context) ([]SessionMeta, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT s.share_code, s.title, s.session_date::text,
		       coalesce(pc.player_count, 0), coalesce(gc.total_games, 0),
		       (s.status <> 'draft') AS locked
		FROM sessions s
		LEFT JOIN (
			SELECT sp.session_id, count(*)::integer AS player_count
			FROM session_players sp GROUP BY sp.session_id
		) pc ON pc.session_id = s.id
		LEFT JOIN (
			SELECT sg.session_id, count(*)::integer AS total_games
			FROM scheduled_games sg GROUP BY sg.session_id
		) gc ON gc.session_id = s.id
		ORDER BY s.session_date DESC, s.updated_at DESC`)
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

// ── helpers write-path ─────────────────────────────────────────────────────
