package store

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
)

// ── Swap granular (clean break) ─────────────────────────────────────────────
// Berdasarkan review skema VPS (000013):
//   - scheduled_game_players: UNIQUE(sg, session_player), UNIQUE(sg, team, position),
//     CHECK team ∈ {A,B}, position ∈ {0,1}
//   - scheduled_games: UNIQUE(session, slot_index, court_index)
//
// Player/team swap antar 2 game beda = 2 UPDATE (tanpa temp) karena target
// row ada di game berbeda → UNIQUE(sg, player) tidak bentrok.
// Slot swap = 3-step pakai temp slot (UNIQUE(session, slot, court)) + serialisasi
// via advisory lock per session (temp collision antar concurrent swap).

// SwapTarget — posisi anggota di satu game (mirror FE SwapTarget).
type SwapTarget struct {
	Slot     int    `json:"slot"`
	Court    int    `json:"court"`
	Team     string `json:"team"`
	Position int    `json:"position"`
}

// SwapMembers — granular swap (player | team | slot).
// Session-level OCC (If-Match session version) + advisory lock untuk slot swap.
func (s *SessionStore) SwapMembers(ctx context.Context, sessionID string, kind string, a, b SwapTarget, expectedSessionVersion *int, idempotencyKey string) (*domain.CloudSnapshot, error) {
	kind = strings.ToLower(strings.TrimSpace(kind))
	switch kind {
	case "player", "team", "slot":
	default:
		return nil, fmt.Errorf("%w: swap type must be player|team|slot", ErrValidation)
	}
	if a.Slot < 0 || a.Court < 0 || b.Slot < 0 || b.Court < 0 {
		return nil, fmt.Errorf("%w: swap targets must be non-negative", ErrValidation)
	}
	if a.Slot == b.Slot && a.Court == b.Court {
		if kind == "slot" {
			return nil, fmt.Errorf("%w: swap targets must be different games", ErrValidation)
		}
		// player/team swap within same game is allowed (e.g., swap partners)
		// must be different positions
		if a.Team == b.Team && a.Position == b.Position {
			return nil, fmt.Errorf("%w: swap targets must be different positions", ErrValidation)
		}
	}
	if kind != "slot" {
		if a.Team != "A" && a.Team != "B" {
			return nil, fmt.Errorf("%w: swap target team must be A or B", ErrValidation)
		}
		if a.Position != 0 && a.Position != 1 {
			return nil, fmt.Errorf("%w: swap target position must be 0 or 1", ErrValidation)
		}
	}
	if kind != "slot" {
		if b.Team != "A" && b.Team != "B" {
			return nil, fmt.Errorf("%w: swap target team must be A or B", ErrValidation)
		}
		if b.Position != 0 && b.Position != 1 {
			return nil, fmt.Errorf("%w: swap target position must be 0 or 1", ErrValidation)
		}
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// Resolve session + lock (session-level karena swap mengubah struktur schedule).
	var sessID, status string
	var currentVer int
	err = tx.QueryRow(ctx, `SELECT s.id::text, s.status, s.version FROM sessions s
		WHERE s.share_code=$1 OR s.id::text=$1 ORDER BY (s.share_code=$1) DESC LIMIT 1
		FOR UPDATE NOWAIT`, sessionID).Scan(&sessID, &status, &currentVer)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		if isLockNotAvailable(err) {
			return nil, ErrContention
		}
		return nil, err
	}
	// Idempotency SEBELUM status/version check (replay sukses bypass lock/version)
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
	if expectedSessionVersion != nil && *expectedSessionVersion != currentVer {
		s.metrics.GranularConflicts.Add(1)
		return nil, fmt.Errorf("%w: expected %d, actual %d", ErrVersionMismatch, *expectedSessionVersion, currentVer)
	}

	// Same-game swap (player/team within same slot/court) — use single-game handler
	if a.Slot == b.Slot && a.Court == b.Court {
		switch kind {
		case "player":
			err = s.swapPlayerSameGame(ctx, tx, sessID, a, b)
		case "team":
			err = s.swapTeamSameGame(ctx, tx, sessID, a, b)
		case "slot":
			// already rejected above, but keep for safety
			return nil, fmt.Errorf("%w: swap targets must be different games", ErrValidation)
		}
	} else {
		switch kind {
		case "slot":
			err = s.swapSlots(ctx, tx, sessID, a, b)
		case "player":
			err = s.swapPlayer(ctx, tx, sessID, a, b)
		case "team":
			err = s.swapTeam(ctx, tx, sessID, a, b)
		}
	}
	if err != nil {
		return nil, err
	}

	// sessions.version +1 (struktur schedule berubah — snapshot konsumen perlu tahu)
	if _, err := tx.Exec(ctx, `UPDATE sessions SET version = version + 1, updated_at = now() WHERE id = $1::uuid`, sessID); err != nil {
		return nil, err
	}
	_ = InsertOutbox(ctx, tx, sessID, domain.OutboxEvent{
		Aggregate: "session", AggregateID: sessID, EventType: "swap",
		Payload: map[string]any{"type": kind, "a": a, "b": b}, Version: int64(currentVer + 1),
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

// lockTwoGames — kunci 2 game secara deterministik (ORDER BY slot, court) biar deadlock-free.
// Return internal_id kedua game (aID, bID).
func lockTwoGames(ctx context.Context, tx pgx.Tx, sessID string, a, b SwapTarget) (string, string, error) {
	rows, err := tx.Query(ctx, `
		SELECT internal_id::text, slot_index, court_index
		FROM scheduled_games
		WHERE session_id = $1::uuid AND
		      ((slot_index = $2 AND court_index = $3) OR (slot_index = $4 AND court_index = $5))
		ORDER BY slot_index, court_index
		FOR UPDATE NOWAIT`, sessID, a.Slot, a.Court, b.Slot, b.Court)
	if err != nil {
		if isLockNotAvailable(err) {
			return "", "", ErrContention
		}
		return "", "", err
	}
	defer rows.Close()
	var aID, bID string
	foundA, foundB := false, false
	for rows.Next() {
		var id string
		var slot, court int
		if err := rows.Scan(&id, &slot, &court); err != nil {
			return "", "", err
		}
		if slot == a.Slot && court == a.Court {
			aID, foundA = id, true
		}
		if slot == b.Slot && court == b.Court {
			bID, foundB = id, true
		}
	}
	if err := rows.Err(); err != nil {
		return "", "", err
	}
	if !foundA || !foundB {
		return "", "", fmt.Errorf("%w: one or both swap targets not found", ErrValidation)
	}
	return aID, bID, nil
}

// swapSlots — 3-step swap slot_index/court_index (UNIQUE(session, slot, court)).
func (s *SessionStore) swapSlots(ctx context.Context, tx pgx.Tx, sessID string, a, b SwapTarget) error {
	// Serialisasi per session — cegah temp slot collision antar swap concurrent.
	var locked bool
	if err := tx.QueryRow(ctx, `SELECT pg_try_advisory_xact_lock(hashtextextended($1 || ':swap:' || $2, 0))`,
		s.schema+".swap", sessID).Scan(&locked); err != nil {
		return err
	}
	if !locked {
		return ErrContention
	}
	aID, bID, err := lockTwoGames(ctx, tx, sessID, a, b)
	if err != nil {
		return err
	}
	const tempSlot = 1 << 20 // jauh di atas slot real (max < 10000)
	if _, err := tx.Exec(ctx, `
		UPDATE scheduled_games SET slot_index = $2, court_index = 0, version = version + 1, updated_at = now()
		WHERE internal_id = $1::uuid`, aID, tempSlot); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		UPDATE scheduled_games SET slot_index = $2, court_index = $3, version = version + 1, updated_at = now()
		WHERE internal_id = $1::uuid`, bID, a.Slot, a.Court); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		UPDATE scheduled_games SET slot_index = $2, court_index = $3, version = version + 1, updated_at = now()
		WHERE internal_id = $1::uuid`, aID, b.Slot, b.Court); err != nil {
		return err
	}
	return nil
}

// swapPlayer — tukar 1 pemain antara 2 game beda (2-step, tanpa temp).
func (s *SessionStore) swapPlayer(ctx context.Context, tx pgx.Tx, sessID string, a, b SwapTarget) error {
	aID, bID, err := lockTwoGames(ctx, tx, sessID, a, b)
	if err != nil {
		return err
	}
	// Ambil session_player_internal_id kedua slot
	var playerA, playerB string
	if err := tx.QueryRow(ctx, `
		SELECT session_player_internal_id::text FROM scheduled_game_players
		WHERE scheduled_game_internal_id = $1::uuid AND team = $2 AND position = $3`,
		aID, a.Team, a.Position).Scan(&playerA); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("%w: player slot A not found", ErrValidation)
		}
		return err
	}
	if err := tx.QueryRow(ctx, `
		SELECT session_player_internal_id::text FROM scheduled_game_players
		WHERE scheduled_game_internal_id = $1::uuid AND team = $2 AND position = $3`,
		bID, b.Team, b.Position).Scan(&playerB); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("%w: player slot B not found", ErrValidation)
		}
		return err
	}
	// Step 1: B ← A (B's slot ambil player dari A). UNIQUE(B, player): A's player tidak ada di B.
	if _, err := tx.Exec(ctx, `
		UPDATE scheduled_game_players SET session_player_internal_id = $2::uuid
		WHERE scheduled_game_internal_id = $1::uuid AND team = $3 AND position = $4`,
		bID, playerA, b.Team, b.Position); err != nil {
		return err
	}
	// Step 2: A ← B
	if _, err := tx.Exec(ctx, `
		UPDATE scheduled_game_players SET session_player_internal_id = $2::uuid
		WHERE scheduled_game_internal_id = $1::uuid AND team = $3 AND position = $4`,
		aID, playerB, a.Team, a.Position); err != nil {
		return err
	}
	// Bump version kedua game
	if _, err := tx.Exec(ctx, `UPDATE scheduled_games SET version = version + 1, updated_at = now()
		WHERE internal_id IN ($1::uuid, $2::uuid)`, aID, bID); err != nil {
		return err
	}
	return nil
}

// swapTeam — tukar satu tim (2 pemain) antara 2 game beda (2-step per posisi).
func (s *SessionStore) swapTeam(ctx context.Context, tx pgx.Tx, sessID string, a, b SwapTarget) error {
	// Normalisasi: swap team letter a.Team ↔ b.Team (posisi 0 & 1 kedua tim).
	// Target b harus memakai team yang sama (FE TeamSwapTarget) — enforce konsistensi.
	if a.Team != b.Team {
		return fmt.Errorf("%w: team swap requires same team letter on both targets", ErrValidation)
	}
	aID, bID, err := lockTwoGames(ctx, tx, sessID, a, b)
	if err != nil {
		return err
	}
	for pos := 0; pos <= 1; pos++ {
		var playerA, playerB string
		if err := tx.QueryRow(ctx, `
			SELECT session_player_internal_id::text FROM scheduled_game_players
			WHERE scheduled_game_internal_id = $1::uuid AND team = $2 AND position = $3`,
			aID, a.Team, pos).Scan(&playerA); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return fmt.Errorf("%w: player A pos %d not found", ErrValidation, pos)
			}
			return err
		}
		if err := tx.QueryRow(ctx, `
			SELECT session_player_internal_id::text FROM scheduled_game_players
			WHERE scheduled_game_internal_id = $1::uuid AND team = $2 AND position = $3`,
			bID, b.Team, pos).Scan(&playerB); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return fmt.Errorf("%w: player B pos %d not found", ErrValidation, pos)
			}
			return err
		}
		if _, err := tx.Exec(ctx, `
			UPDATE scheduled_game_players SET session_player_internal_id = $2::uuid
			WHERE scheduled_game_internal_id = $1::uuid AND team = $3 AND position = $4`,
			bID, playerA, b.Team, pos); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			UPDATE scheduled_game_players SET session_player_internal_id = $2::uuid
			WHERE scheduled_game_internal_id = $1::uuid AND team = $3 AND position = $4`,
			aID, playerB, a.Team, pos); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE scheduled_games SET version = version + 1, updated_at = now()
		WHERE internal_id IN ($1::uuid, $2::uuid)`, aID, bID); err != nil {
		return err
	}
	return nil
}

// swapPlayerSameGame — tukar 2 pemain dalam 1 game yang sama (DELETE+INSERT, hindari UNIQUE violation).
func (s *SessionStore) swapPlayerSameGame(ctx context.Context, tx pgx.Tx, sessID string, a, b SwapTarget) error {
	var gameID string
	if err := tx.QueryRow(ctx, `
		SELECT internal_id::text FROM scheduled_games
		WHERE session_id = $1::uuid AND slot_index = $2 AND court_index = $3
		FOR UPDATE NOWAIT`, sessID, a.Slot, a.Court).Scan(&gameID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("%w: game not found", ErrValidation)
		}
		if isLockNotAvailable(err) {
			return ErrContention
		}
		return err
	}
	var playerA, playerB string
	if err := tx.QueryRow(ctx, `
		SELECT session_player_internal_id::text FROM scheduled_game_players
		WHERE scheduled_game_internal_id = $1::uuid AND team = $2 AND position = $3`,
		gameID, a.Team, a.Position).Scan(&playerA); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("%w: player slot A not found", ErrValidation)
		}
		return err
	}
	if err := tx.QueryRow(ctx, `
		SELECT session_player_internal_id::text FROM scheduled_game_players
		WHERE scheduled_game_internal_id = $1::uuid AND team = $2 AND position = $3`,
		gameID, b.Team, b.Position).Scan(&playerB); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("%w: player slot B not found", ErrValidation)
		}
		return err
	}
	if playerA == playerB {
		return fmt.Errorf("%w: cannot swap same player", ErrValidation)
	}
	// DELETE both rows dulu, baru INSERT dengan player tertukar — hindari UNIQUE(sg, player) violation
	if _, err := tx.Exec(ctx, `
		DELETE FROM scheduled_game_players
		WHERE scheduled_game_internal_id = $1::uuid
		  AND ((team = $2 AND position = $3) OR (team = $4 AND position = $5))`,
		gameID, a.Team, a.Position, b.Team, b.Position); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO scheduled_game_players (scheduled_game_internal_id, team, position, session_player_internal_id)
		VALUES ($1::uuid, $2, $3, $4::uuid), ($1::uuid, $5, $6, $7::uuid)`,
		gameID, a.Team, a.Position, playerB, b.Team, b.Position, playerA); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE scheduled_games SET version = version + 1, updated_at = now() WHERE internal_id = $1::uuid`, gameID); err != nil {
		return err
	}
	return nil
}

// swapTeamSameGame — tukar 2 tim dalam 1 game yang sama (swap A<->B dalam game yang sama).
func (s *SessionStore) swapTeamSameGame(ctx context.Context, tx pgx.Tx, sessID string, a, b SwapTarget) error {
	if a.Team == b.Team {
		return fmt.Errorf("%w: team swap within same game requires different teams (A vs B)", ErrValidation)
	}
	var gameID string
	if err := tx.QueryRow(ctx, `
		SELECT internal_id::text FROM scheduled_games
		WHERE session_id = $1::uuid AND slot_index = $2 AND court_index = $3
		FOR UPDATE NOWAIT`, sessID, a.Slot, a.Court).Scan(&gameID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("%w: game not found", ErrValidation)
		}
		if isLockNotAvailable(err) {
			return ErrContention
		}
		return err
	}
	var a0, a1, b0, b1 string
	if err := tx.QueryRow(ctx, `SELECT session_player_internal_id::text FROM scheduled_game_players WHERE scheduled_game_internal_id = $1::uuid AND team = 'A' AND position = 0`, gameID).Scan(&a0); err != nil {
		return err
	}
	if err := tx.QueryRow(ctx, `SELECT session_player_internal_id::text FROM scheduled_game_players WHERE scheduled_game_internal_id = $1::uuid AND team = 'A' AND position = 1`, gameID).Scan(&a1); err != nil {
		return err
	}
	if err := tx.QueryRow(ctx, `SELECT session_player_internal_id::text FROM scheduled_game_players WHERE scheduled_game_internal_id = $1::uuid AND team = 'B' AND position = 0`, gameID).Scan(&b0); err != nil {
		return err
	}
	if err := tx.QueryRow(ctx, `SELECT session_player_internal_id::text FROM scheduled_game_players WHERE scheduled_game_internal_id = $1::uuid AND team = 'B' AND position = 1`, gameID).Scan(&b1); err != nil {
		return err
	}
	// DELETE 4 rows dulu, baru INSERT dengan team tertukar — hindari UNIQUE violation
	if _, err := tx.Exec(ctx, `DELETE FROM scheduled_game_players WHERE scheduled_game_internal_id = $1::uuid`, gameID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO scheduled_game_players (scheduled_game_internal_id, team, position, session_player_internal_id)
		VALUES ($1::uuid, 'A', 0, $2::uuid), ($1::uuid, 'A', 1, $3::uuid), ($1::uuid, 'B', 0, $4::uuid), ($1::uuid, 'B', 1, $5::uuid)`,
		gameID, b0, b1, a0, a1); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE scheduled_games SET version = version + 1, updated_at = now() WHERE internal_id = $1::uuid`, gameID); err != nil {
		return err
	}
	return nil
}
