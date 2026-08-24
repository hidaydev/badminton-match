package domain

import "time"

// OutboxEvent — event durable untuk SSE patch (Fase 0 additive, belum dipakai write path).
// Disimpan di outbox_events, di-notify via pg_notify, di-konsumsi SSE Watch.
type OutboxEvent struct {
	ID          int64     `json:"id"`
	SessionID   string    `json:"session_id"`
	Aggregate   string    `json:"aggregate"`    // 'game' | 'player' | 'session'
	AggregateID string    `json:"aggregate_id"` // '0-0' | player_ref
	EventType   string    `json:"event_type"`   // 'score_set' | 'played_toggled' | 'absent_set' | 'swap'
	Payload     any       `json:"payload"`
	Version     int64     `json:"version"`
	CreatedAt   time.Time `json:"created_at"`
}

// GameScorePayload — payload untuk event score_set
type GameScorePayload struct {
	Slot     int `json:"slot"`
	Court    int `json:"court"`
	ScoreA   int `json:"scoreA"`
	ScoreB   int `json:"scoreB"`
	IsPlayed bool `json:"isPlayed"`
}

// PlayedPayload — payload untuk played_toggled
type PlayedPayload struct {
	Slot     int  `json:"slot"`
	Court    int  `json:"court"`
	IsPlayed bool `json:"isPlayed"`
}

// AbsentPayload — payload untuk absent_set
type AbsentPayload struct {
	PlayerIDs []string `json:"playerIds"`
}
