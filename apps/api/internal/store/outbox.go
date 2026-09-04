package store

import (
	"context"
	"encoding/json"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
)

// Outbox — helper untuk event durable (Fase 0 additive, belum dipakai critical path).

// InsertOutbox — insert event ke outbox_events dalam transaksi yang sama.
// No-op jika tabel belum ada (migration belum apply) — return nil agar transaksi utama tetap commit.
func InsertOutbox(ctx context.Context, tx pgx.Tx, sessionID string, ev domain.OutboxEvent) error {
	payload, _ := json.Marshal(ev.Payload)
	_, err := tx.Exec(ctx, `
		INSERT INTO outbox_events (session_id, aggregate, aggregate_id, event_type, payload, version)
		VALUES ($1::uuid, $2, $3, $4, $5::jsonb, $6)`, sessionID, ev.Aggregate, ev.AggregateID, ev.EventType, payload, ev.Version)
	if err != nil && isUndefinedTable(err) {
		return nil // backward compat: tabel belum ada → skip
	}
	return err
}

// ListOutboxSince — untuk GET /sessions/{id}/events?since=
func (s *SessionStore) ListOutboxSince(ctx context.Context, sessionID string, sinceID int64, limit int) ([]domain.OutboxEvent, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT id, session_id::text, aggregate, aggregate_id, event_type, payload, version, created_at
		FROM outbox_events WHERE session_id = $1::uuid AND id > $2 ORDER BY id ASC LIMIT $3`, sessionID, sinceID, limit)
	if err != nil {
		if isUndefinedTable(err) {
			return []domain.OutboxEvent{}, nil
		}
		return nil, err
	}
	defer rows.Close()
	var out []domain.OutboxEvent
	for rows.Next() {
		var ev domain.OutboxEvent
		var raw []byte
		if err := rows.Scan(&ev.ID, &ev.SessionID, &ev.Aggregate, &ev.AggregateID, &ev.EventType, &raw, &ev.Version, &ev.CreatedAt); err != nil {
			return nil, err
		}
		_ = json.Unmarshal(raw, &ev.Payload)
		out = append(out, ev)
	}
	return out, rows.Err()
}
