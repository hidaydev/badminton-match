package store

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// IdempotencyStore — persistent idempotency (Fase 0 additive).
// Tabel idempotency_keys (000012). Fallback ke no-op jika tabel belum ada (backward compat).

// rowQuerier — dipenuhi oleh pgx.Tx dan *pgxpool.Pool. Dipakai supaya
// CheckIdempotency bisa query DI DALAM transaksi yang sedang terbuka: memakai
// s.pool saat tx hidup berarti tiap request memegang 2 koneksi → risiko pool
// exhaustion/deadlock di bawah concurrency.
type rowQuerier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// CheckIdempotency — cek apakah key sudah ada dan belum expired.
// Return (cached snapshot, true) jika hit, (nil, false) jika miss atau tabel belum ada.
func (s *SessionStore) CheckIdempotency(ctx context.Context, q rowQuerier, sessionID, key string) (*domain.CloudSnapshot, bool) {
	var raw []byte
	var expires time.Time
	err := q.QueryRow(ctx, `
		SELECT response, expires_at FROM idempotency_keys
		WHERE session_id = $1::uuid AND key = $2 AND expires_at > now()`, sessionID, key).Scan(&raw, &expires)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, false
		}
		// Tabel belum ada (migration belum apply) → miss, jangan error.
		if isUndefinedTable(err) {
			return nil, false
		}
		// Error lain: fail-open (idempotency best-effort) tapi jangan telan diam-diam.
		if s.logger != nil {
			s.logger.Warn("idempotency check failed; treating as miss", "session_id", sessionID, "error", err)
		}
		return nil, false
	}
	var snap domain.CloudSnapshot
	if err := json.Unmarshal(raw, &snap); err != nil {
		return nil, false
	}
	return &snap, true
}

// SaveIdempotency — simpan response untuk key (24h TTL). No-op jika tabel belum ada.
func (s *SessionStore) SaveIdempotency(ctx context.Context, sessionID, key string, snap *domain.CloudSnapshot) {
	raw, _ := json.Marshal(snap)
	_, err := s.pool.Exec(ctx, `
		INSERT INTO idempotency_keys (session_id, key, response, expires_at)
		VALUES ($1::uuid, $2, $3::jsonb, now() + interval '24 hours')
		ON CONFLICT (session_id, key) DO NOTHING`, sessionID, key, raw)
	if err != nil && !isUndefinedTable(err) {
		// best-effort, jangan gagalkan transaksi utama
		return
	}
	_ = err
}

// isUndefinedTable — cek pgcode 42P01 (undefined_table) atau invalid input (22P02) untuk fallback share_code
func isUndefinedTable(err error) bool {
	if err == nil {
		return false
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code == "42P01" || pgErr.Code == "42P07"
	}
	// Fallback string (untuk error wrap yang tidak preserve pgconn)
	msg := err.Error()
	return strings.Contains(msg, "42P01") || strings.Contains(msg, "does not exist") || strings.Contains(msg, "42P07")
}
