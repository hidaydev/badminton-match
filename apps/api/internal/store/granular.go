package store

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// ── Granular live ops (Fase 1) — row-level OCC, tanpa session-level lock ───
// Semua method di sini adalah clean break dari snapshot PUT.
// Mereka hanya menyentuh 1-2 baris, tidak DELETE+INSERT, dan tidak validasi full snapshot.

// GameRow — satu game dari scheduled_games (granular read).
type GameRow struct {
	Slot        int      `json:"slot"`
	Court       int      `json:"court"`
	ScoreA      *int     `json:"scoreA"`
	ScoreB      *int     `json:"scoreB"`
	IsPlayed    bool     `json:"isPlayed"`
	Version     int      `json:"version"`
	SkippedRefs []string `json:"skippedRefs"`
}

// GetGame — ambil satu game + version-nya (untuk If-Match granular).
func (s *SessionStore) GetGame(ctx context.Context, sessionID, gameKey string) (*GameRow, error) {
	slot, court, ok := splitGameKey(gameKey)
	if !ok {
		return nil, fmt.Errorf("%w: invalid gameKey %q", ErrValidation, gameKey)
	}
	var g GameRow
	var scoreA, scoreB *int
	var skipped []string
	err := s.pool.QueryRow(ctx, `
		SELECT sg.slot_index, sg.court_index, sg.score_a, sg.score_b, sg.is_played, sg.version,
		       COALESCE(sg.skipped_player_refs, '{}')
		FROM scheduled_games sg
		JOIN sessions s ON s.id = sg.session_id
		WHERE (s.share_code = $1 OR s.id::text = $1) AND sg.slot_index = $2 AND sg.court_index = $3
		ORDER BY (s.share_code = $1) DESC LIMIT 1`, sessionID, slot, court).Scan(&g.Slot, &g.Court, &scoreA, &scoreB, &g.IsPlayed, &g.Version, &skipped)
	if err != nil {
		if isUndefinedColumn(err) {
			// Fallback jika migration 000014 belum applied (rare, backward-compat)
			err2 := s.pool.QueryRow(ctx, `
				SELECT sg.slot_index, sg.court_index, sg.score_a, sg.score_b, sg.is_played, sg.version
				FROM scheduled_games sg
				JOIN sessions s ON s.id = sg.session_id
				WHERE (s.share_code = $1 OR s.id::text = $1) AND sg.slot_index = $2 AND sg.court_index = $3
				ORDER BY (s.share_code = $1) DESC LIMIT 1`, sessionID, slot, court).Scan(&g.Slot, &g.Court, &scoreA, &scoreB, &g.IsPlayed, &g.Version)
			if errors.Is(err2, pgx.ErrNoRows) {
				return nil, ErrNotFound
			}
			if err2 != nil {
				return nil, err2
			}
			skipped = []string{}
		} else {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, ErrNotFound
			}
			return nil, err
		}
	} else {
		if skipped == nil {
			skipped = []string{}
		}
	}
	if scoreA != nil {
		g.ScoreA = scoreA
		g.ScoreB = scoreB
	}
	g.SkippedRefs = skipped
	return &g, nil
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

	// Idempotency check SEBELUM status/version check — replay request yang
	// sudah sukses harus return response cached walau session sudah ter-lock
	// atau version naik (dedup, bukan write baru).
	if idempotencyKey != "" {
		if cached, hit := s.CheckIdempotency(ctx, sessID, idempotencyKey); hit && cached != nil {
			s.metrics.IdempotencyHits.Add(1)
			_ = tx.Rollback(ctx)
			return cached, nil
		}
	}
	if status != "draft" {
		return nil, ErrLocked
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
		s.metrics.GranularConflicts.Add(1)
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
	s.metrics.OutboxEvents.Add(1)

	// Auto-lock saat SEMUA game sudah ber-skor (mirror Save() allScored) —
	// tanpanya sesi yang skornya masuk via granular tidak pernah ter-lock
	// sampai tanggal lewat → rating ingest tertunda (regression vs PUT path).
	allScored, err := allGamesScored(ctx, tx, sessID)
	if err != nil {
		return nil, err
	}
	if allScored {
		// status='draft' guard → hanya satu writer yang menang; yang kedua
		// tidak menaikkan version lagi (idempotent lock).
		_, err = tx.Exec(ctx, `
			UPDATE sessions SET status = 'locked', version = version + 1, updated_at = now()
			WHERE id = $1::uuid AND status = 'draft'`, sessID)
		if err != nil {
			return nil, err
		}
		s.metrics.AutoLocks.Add(1)
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	// Idempotency save (best-effort, after commit agar tidak block)
	snap, err := s.Load(ctx, sessionID)
	if err == nil && snap != nil {
		s.Broadcast(sessionID, snap)
		s.metrics.GranularOps.Add(1)
		if idempotencyKey != "" {
			s.SaveIdempotency(ctx, sessID, idempotencyKey, snap)
		}
	}
	return snap, err
}

// allGamesScored — true jika semua game di session sudah punya score (score_a IS NOT NULL).
func allGamesScored(ctx context.Context, tx pgx.Tx, sessionID string) (bool, error) {
	var remaining int
	err := tx.QueryRow(ctx, `
		SELECT count(*) FROM scheduled_games
		WHERE session_id = $1::uuid AND score_a IS NULL`, sessionID).Scan(&remaining)
	if err != nil {
		return false, err
	}
	return remaining == 0, nil
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
	// Idempotency SEBELUM status check (replay sukses harus bypass lock/version)
	if idempotencyKey != "" {
		if cached, hit := s.CheckIdempotency(ctx, sessID, idempotencyKey); hit && cached != nil {
			s.metrics.IdempotencyHits.Add(1)
			_ = tx.Rollback(ctx)
			return cached, nil
		}
	}
	if status != "draft" {
		return nil, ErrLocked
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
		s.metrics.GranularConflicts.Add(1)
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
	s.metrics.OutboxEvents.Add(1)
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	snap, err := s.Load(ctx, sessionID)
	if err == nil && snap != nil {
		s.Broadcast(sessionID, snap)
		s.metrics.GranularOps.Add(1)
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
			s.metrics.IdempotencyHits.Add(1)
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
		s.metrics.GranularConflicts.Add(1)
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
	s.metrics.OutboxEvents.Add(1)
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	snap, err := s.Load(ctx, sessionID)
	if err == nil && snap != nil {
		s.Broadcast(sessionID, snap)
		s.metrics.GranularOps.Add(1)
		if idempotencyKey != "" {
			s.SaveIdempotency(ctx, sessID, idempotencyKey, snap)
		}
	}
	return snap, err
}

// SetGameSkipped — granular skip per-game: row-level OCC, clear score if skipped.
func (s *SessionStore) SetGameSkipped(ctx context.Context, sessionID, gameKey string, playerRefs []string, expectedVersion *int, idempotencyKey string) (*domain.CloudSnapshot, error) {
	slot, court, ok := splitGameKey(gameKey)
	if !ok {
		return nil, fmt.Errorf("%w: invalid gameKey %q", ErrValidation, gameKey)
	}
	clean := []string{}
	seen := map[string]struct{}{}
	for _, r := range playerRefs {
		rr := strings.TrimSpace(r)
		if rr == "" {
			continue
		}
		if _, dup := seen[rr]; dup {
			return nil, fmt.Errorf("%w: skipped playerRefs must not contain duplicates", ErrValidation)
		}
		seen[rr] = struct{}{}
		clean = append(clean, rr)
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
	if idempotencyKey != "" {
		if cached, hit := s.CheckIdempotency(ctx, sessID, idempotencyKey); hit && cached != nil {
			s.metrics.IdempotencyHits.Add(1)
			_ = tx.Rollback(ctx)
			return cached, nil
		}
	}
	if status != "draft" {
		return nil, ErrLocked
	}
	if len(clean) > 0 {
		for _, ref := range clean {
			var cnt int
			_ = tx.QueryRow(ctx, `SELECT count(*) FROM session_players WHERE session_id=$1::uuid AND player_ref=$2`, sessID, ref).Scan(&cnt)
			if cnt == 0 {
				return nil, fmt.Errorf("%w: skipped playerRefs must only reference known player ids", ErrValidation)
			}
		}
	}
	var currentVer int
	var curSkipped []string
	err = tx.QueryRow(ctx, `SELECT version, COALESCE(skipped_player_refs, '{}') FROM scheduled_games WHERE session_id=$1::uuid AND slot_index=$2 AND court_index=$3 FOR UPDATE NOWAIT`, sessID, slot, court).Scan(&currentVer, &curSkipped)
	if err != nil {
		if isUndefinedColumn(err) {
			err2 := tx.QueryRow(ctx, `SELECT version FROM scheduled_games WHERE session_id=$1::uuid AND slot_index=$2 AND court_index=$3 FOR UPDATE NOWAIT`, sessID, slot, court).Scan(&currentVer)
			if errors.Is(err2, pgx.ErrNoRows) {
				return nil, fmt.Errorf("%w: game %s not found", ErrValidation, gameKey)
			}
			if err2 != nil {
				if isLockNotAvailable(err2) {
					return nil, ErrContention
				}
				return nil, err2
			}
			curSkipped = []string{}
		} else {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, fmt.Errorf("%w: game %s not found", ErrValidation, gameKey)
			}
			if isLockNotAvailable(err) {
				return nil, ErrContention
			}
			return nil, err
		}
	}
	if expectedVersion != nil && *expectedVersion != currentVer {
		s.metrics.GranularConflicts.Add(1)
		return nil, fmt.Errorf("%w: expected %d, actual %d", ErrVersionMismatch, *expectedVersion, currentVer)
	}
	if curSkipped == nil {
		curSkipped = []string{}
	}
	if equalStringSets(curSkipped, clean) {
		_ = tx.Rollback(ctx)
		return s.Load(ctx, sessionID)
	}
	if len(clean) > 0 {
		_, err = tx.Exec(ctx, `UPDATE scheduled_games SET skipped_player_refs=$2, version=version+1, updated_at=now() WHERE session_id=$1::uuid AND slot_index=$3 AND court_index=$4`, sessID, clean, slot, court)
	} else {
		_, err = tx.Exec(ctx, `UPDATE scheduled_games SET skipped_player_refs='{}', version=version+1, updated_at=now() WHERE session_id=$1::uuid AND slot_index=$2 AND court_index=$3`, sessID, slot, court)
	}
	if err != nil {
		if isUndefinedColumn(err) {
			return nil, fmt.Errorf("%w: skipped_player_refs column not yet migrated (apply 000014)", ErrValidation)
		}
		return nil, err
	}
	_ = InsertOutbox(ctx, tx, sessID, domain.OutboxEvent{
		Aggregate: "game", AggregateID: gameKey, EventType: "skipped_set",
		Payload: domain.SkippedPayload{Slot: slot, Court: court, PlayerIDs: clean}, Version: int64(currentVer + 1),
	})
	s.metrics.OutboxEvents.Add(1)
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	snap, err := s.Load(ctx, sessionID)
	if err == nil && snap != nil {
		s.Broadcast(sessionID, snap)
		s.metrics.GranularOps.Add(1)
		if idempotencyKey != "" {
			s.SaveIdempotency(ctx, sessID, idempotencyKey, snap)
		}
	}
	return snap, err
}
func equalStringSets(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	m := make(map[string]int, len(a))
	for _, s := range a {
		m[s]++
	}
	for _, s := range b {
		if c, ok := m[s]; !ok || c == 0 {
			return false
		}
		m[s]--
	}
	return true
}
func isUndefinedColumn(err error) bool {
	if err == nil {
		return false
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code == "42703"
	}
	msg := err.Error()
	return strings.Contains(msg, "42703") || strings.Contains(msg, "skipped_player_refs") && strings.Contains(msg, "does not exist")
}
