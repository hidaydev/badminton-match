package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
)

// IdempotencyStore — persistent idempotency (Fase 0 additive).
// Tabel idempotency_keys (000012). Fallback ke no-op jika tabel belum ada (backward compat).

// CheckIdempotency — cek apakah key sudah ada dan belum expired.
// Return (cached snapshot, true) jika hit, (nil, false) jika miss atau tabel belum ada.
func (s *SessionStore) CheckIdempotency(ctx context.Context, sessionID, key string) (*domain.CloudSnapshot, bool) {
	var raw []byte
	var expires time.Time
	err := s.pool.QueryRow(ctx, `
		SELECT response, expires_at FROM idempotency_keys
		WHERE session_id = $1::uuid AND key = $2 AND expires_at > now()`, sessionID, key).Scan(&raw, &expires)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, false
		}
		// Tabel belum ada (migration belum apply) → miss, jangan error
		if isUndefinedTable(err) {
			return nil, false
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

// isUndefinedTable — cek pgcode 42P01 (undefined_table)
func isUndefinedTable(err error) bool {
	if err == nil {
		return false
	}
	// pgx wraps pgconn.PgError — cek via string fallback agar tidak import pgconn di domain
	return contains(err.Error(), "42P01") || contains(err.Error(), "does not exist")
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (func() bool {
		for i := 0; i <= len(s)-len(substr); i++ {
			if s[i:i+len(substr)] == substr {
				return true
			}
		}
		return false
	})()
}
