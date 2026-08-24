package store

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
)

// ── Granular live ops (Fase 1) — row-level OCC, tanpa session-level lock ───
// Semua method di sini adalah clean break dari snapshot PUT.
// Mereka hanya menyentuh 1-2 baris, tidak DELETE+INSERT, dan tidak validasi full snapshot.

// GameVersion — ambil version per game (scheduled_games.version)
func (s *SessionStore) GetGameVersion(ctx context.Context, sessionID string, slot, court int) (int, error) {
	var v int
	err := s.pool.QueryRow(ctx, `
		SELECT sg.version FROM scheduled_games sg
		JOIN sessions s ON s.id = sg.session_id
		WHERE (s.share_code = $1 OR s.id::text = $1) AND sg.slot_index = $2 AND sg.court_index = $3
		ORDER BY (s.share_code = $1) DESC LIMIT 1`, sessionID, slot, court).Scan(&v)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, ErrNotFound
	}
	return v, err
}

// SetGameScore — granular score: row-level FOR UPDATE, OCC per game, idempotency persistent.
// expectedVersion = version game saat ini (dari GET atau ETag). nil = tanpa check (tidak disarankan).
// idempotencyKey = header Idempotency-Key, "" = tanpa dedup.
func (s *SessionStore) SetGameScore(ctx context.Context, sessionID, gameKey string, scoreA, scoreB int, expectedVersion *int, idempotencyKey string) (*domain.CloudSnapshot, error) {
	slot, court, ok := splitGameKey(gameKey)
	if !ok {
		return nil, fmt.Errorf("%w: invalid gameKey %q", ErrValidation, gameKey)
	}
	if err := domain.ValidateScore(scoreA, scoreB); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrValidation, err)
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// Resolve session id + status + lock check (tanpa FOR UPDATE sessions agar tidak contention)
	var sessID, status string
	err = tx.QueryRow(ctx, `
		SELECT s.id::text, s.status FROM sessions s
		WHERE s.share_code = $1 OR s.id::text = $1
		ORDER BY (s.share_code = $1) DESC LIMIT 1`, sessionID).Scan(&sessID, &status)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if status != "draft" {
		return nil, ErrLocked
	}

	// Idempotency check setelah resolve sessID (pakai UUID, bukan share_code)
	if idempotencyKey != "" {
		if cached, hit := s.CheckIdempotency(ctx, sessID, idempotencyKey); hit && cached != nil {
			_ = tx.Rollback(ctx)
			return cached, nil
		}
	}

	// Row-level lock game spesifik — ini yang bikin 2 game beda tidak saling blokir
	var currentVer int
	var exists bool
	err = tx.QueryRow(ctx, `
		SELECT version FROM scheduled_games
		WHERE session_id = $1::uuid AND slot_index = $2 AND court_index = $3
		FOR UPDATE NOWAIT`, sessID, slot, court).Scan(&currentVer)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		exists = false
	case err != nil:
		if isLockNotAvailable(err) {
			return nil, ErrContention
		}
		return nil, err
	default:
		exists = true
	}
	if !exists {
		return nil, fmt.Errorf("%w: game %s not found", ErrValidation, gameKey)
	}
	if expectedVersion != nil && *expectedVersion != currentVer {
		return nil, fmt.Errorf("%w: expected %d, actual %d", ErrVersionMismatch, *expectedVersion, currentVer)
	}

	// Update score + is_played + version + updated_at (trigger) + played_order
	// played_order = legacy_order+1 jika belum played (mirror syncSessionTables)
	var legacyOrder int
	_ = tx.QueryRow(ctx, `SELECT legacy_order FROM scheduled_games WHERE session_id=$1::uuid AND slot_index=$2 AND court_index=$3`, sessID, slot, court).Scan(&legacyOrder)
	playedOrder := legacyOrder + 1
	_, err = tx.Exec(ctx, `
		UPDATE scheduled_games
		SET score_a = $2, score_b = $3, is_played = true, status = 'played',
		    played_order = CASE WHEN is_played THEN played_order ELSE $4 END,
		    version = version + 1, updated_at = now()
		WHERE session_id = $1::uuid AND slot_index = $5 AND court_index = $6`, sessID, scoreA, scoreB, playedOrder, slot, court)
	if err != nil {
		return nil, err
	}

	// Outbox event (durable SSE)
	_ = InsertOutbox(ctx, tx, sessID, domain.OutboxEvent{
		Aggregate:   "game",
		AggregateID: gameKey,
		EventType:   "score_set",
		Payload:     domain.GameScorePayload{Slot: slot, Court: court, ScoreA: scoreA, ScoreB: scoreB, IsPlayed: true},
		Version:     int64(currentVer + 1),
	})

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	// Idempotency save (best-effort, after commit agar tidak block)
	snap, err := s.Load(ctx, sessionID)
	if err == nil && snap != nil {
		s.Broadcast(sessionID, snap)
		if idempotencyKey != "" {
			s.SaveIdempotency(ctx, sessID, idempotencyKey, snap)
		}
	}
	return snap, err
}

// SetGamePlayed — granular played toggle (idempotent set, bukan toggle)
func (s *SessionStore) SetGamePlayed(ctx context.Context, sessionID, gameKey string, isPlayed bool, expectedVersion *int, idempotencyKey string) (*domain.CloudSnapshot, error) {
	slot, court, ok := splitGameKey(gameKey)
	if !ok {
		return nil, fmt.Errorf("%w: invalid gameKey %q", ErrValidation, gameKey)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var sessID, status string
	err = tx.QueryRow(ctx, `SELECT s.id::text, s.status FROM sessions s WHERE s.share_code=$1 OR s.id::text=$1 ORDER BY (s.share_code=$1) DESC LIMIT 1`, sessionID).Scan(&sessID, &status)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if status != "draft" {
		return nil, ErrLocked
	}
	if idempotencyKey != "" {
		if cached, hit := s.CheckIdempotency(ctx, sessID, idempotencyKey); hit && cached != nil {
			_ = tx.Rollback(ctx)
			return cached, nil
		}
	}
	var currentVer int
	var curPlayed bool
	err = tx.QueryRow(ctx, `SELECT version, is_played FROM scheduled_games WHERE session_id=$1::uuid AND slot_index=$2 AND court_index=$3 FOR UPDATE NOWAIT`, sessID, slot, court).Scan(&currentVer, &curPlayed)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("%w: game %s not found", ErrValidation, gameKey)
	}
	if err != nil {
		if isLockNotAvailable(err) {
			return nil, ErrContention
		}
		return nil, err
	}
	if expectedVersion != nil && *expectedVersion != currentVer {
		return nil, fmt.Errorf("%w: expected %d, actual %d", ErrVersionMismatch, *expectedVersion, currentVer)
	}
	// Idempotent: jika sudah sesuai, no-op tapi tetap return snapshot
	if curPlayed == isPlayed {
		_ = tx.Rollback(ctx)
		return s.Load(ctx, sessionID)
	}
	var playedOrder *int
	if isPlayed {
		var legacy int
		_ = tx.QueryRow(ctx, `SELECT legacy_order FROM scheduled_games WHERE session_id=$1::uuid AND slot_index=$2 AND court_index=$3`, sessID, slot, court).Scan(&legacy)
		po := legacy + 1
		playedOrder = &po
	}
	// Jika unplayed, hapus score juga (mirror togglePlayedInSnapshot)
	if isPlayed {
		_, err = tx.Exec(ctx, `UPDATE scheduled_games SET is_played=true, status='played', played_order=$2, version=version+1, updated_at=now() WHERE session_id=$1::uuid AND slot_index=$3 AND court_index=$4`, sessID, playedOrder, slot, court)
	} else {
		_, err = tx.Exec(ctx, `UPDATE scheduled_games SET is_played=false, status='scheduled', played_order=NULL, score_a=NULL, score_b=NULL, version=version+1, updated_at=now() WHERE session_id=$1::uuid AND slot_index=$2 AND court_index=$3`, sessID, slot, court)
	}
	if err != nil {
		return nil, err
	}
	_ = InsertOutbox(ctx, tx, sessID, domain.OutboxEvent{
		Aggregate: "game", AggregateID: gameKey, EventType: "played_toggled",
		Payload: domain.PlayedPayload{Slot: slot, Court: court, IsPlayed: isPlayed}, Version: int64(currentVer + 1),
	})
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	snap, err := s.Load(ctx, sessionID)
	if err == nil && snap != nil {
		s.Broadcast(sessionID, snap)
		if idempotencyKey != "" {
			s.SaveIdempotency(ctx, sessID, idempotencyKey, snap)
		}
	}
	return snap, err
}

// SetAbsentPlayers — granular absent (masih session-level, tapi tanpa full snapshot rewrite)
// Hanya update session_players.is_absent + sessions.include_absent_players
func (s *SessionStore) SetAbsentPlayers(ctx context.Context, sessionID string, playerRefs []string, expectedSessionVersion *int, idempotencyKey string) (*domain.CloudSnapshot, error) {
	// Trim + dedup
	clean := []string{}
	seen := map[string]struct{}{}
	for _, r := range playerRefs {
		rr := strings.TrimSpace(r)
		if rr == "" {
			continue
		}
		if _, dup := seen[rr]; dup {
			return nil, fmt.Errorf("%w: absentPlayers must not contain duplicates", ErrValidation)
		}
		seen[rr] = struct{}{}
		clean = append(clean, rr)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var sessID string
	var currentVer int
	var status string
	err = tx.QueryRow(ctx, `SELECT s.id::text, s.version, s.status FROM sessions s WHERE s.share_code=$1 OR s.id::text=$1 ORDER BY (s.share_code=$1) DESC LIMIT 1 FOR UPDATE NOWAIT`, sessionID).Scan(&sessID, &currentVer, &status)
	if err == nil && idempotencyKey != "" {
		if cached, hit := s.CheckIdempotency(ctx, sessID, idempotencyKey); hit && cached != nil {
			_ = tx.Rollback(ctx)
			return cached, nil
		}
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		if isLockNotAvailable(err) {
			return nil, ErrContention
		}
		return nil, err
	}
	if status != "draft" {
		return nil, ErrLocked
	}
	if expectedSessionVersion != nil && *expectedSessionVersion != currentVer {
		return nil, fmt.Errorf("%w: expected %d, actual %d", ErrVersionMismatch, *expectedSessionVersion, currentVer)
	}
	// Validasi refs harus ada di session_players
	if len(clean) > 0 {
		// cek semua refs ada
		for _, ref := range clean {
			var cnt int
			_ = tx.QueryRow(ctx, `SELECT count(*) FROM session_players WHERE session_id=$1::uuid AND player_ref=$2`, sessID, ref).Scan(&cnt)
			if cnt == 0 {
				return nil, fmt.Errorf("%w: absentPlayers must only reference known non-blank player ids", ErrValidation)
			}
		}
	}
	// Update is_absent + absent_order + include_absent_players + sessions.version
	_, err = tx.Exec(ctx, `UPDATE session_players SET is_absent=false, absent_order=NULL WHERE session_id=$1::uuid`, sessID)
	if err != nil {
		return nil, err
	}
	for i, ref := range clean {
		_, err = tx.Exec(ctx, `UPDATE session_players SET is_absent=true, absent_order=$2 WHERE session_id=$1::uuid AND player_ref=$3`, sessID, i, ref)
		if err != nil {
			return nil, err
		}
	}
	_, err = tx.Exec(ctx, `UPDATE sessions SET include_absent_players=$2, version=version+1, updated_at=now() WHERE id=$1::uuid`, sessID, len(clean) > 0)
	if err != nil {
		return nil, err
	}
	_ = InsertOutbox(ctx, tx, sessID, domain.OutboxEvent{
		Aggregate: "player", AggregateID: "absent", EventType: "absent_set",
		Payload: domain.AbsentPayload{PlayerIDs: clean}, Version: int64(currentVer + 1),
	})
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	snap, err := s.Load(ctx, sessionID)
	if err == nil && snap != nil {
		s.Broadcast(sessionID, snap)
		if idempotencyKey != "" {
			s.SaveIdempotency(ctx, sessID, idempotencyKey, snap)
		}
	}
	return snap, err
}
