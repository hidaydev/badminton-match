package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
)

// ── Admin: tier induk, delete player (ADMIN_MENU_PLAN.md §3.3-3.4) ──

// SetPlayerTier — ubah tier induk (STICKY, admin-only). TIER_8_UNIFICATION:
// players.tier = single source; mengubah tier → RebuildAll supaya baseline
// forming berubah (tier baru dipakai forming ulang).
func (s *SessionStore) SetPlayerTier(ctx context.Context, playerID, tier string) error {
	if !domain.ValidTier(tier) {
		return fmt.Errorf("%w: tier must be 8-tier (D..A+)", ErrValidation)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var exists bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM `+s.schema+`.players WHERE id = $1::uuid)`, playerID).Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return fmt.Errorf("%w: player", ErrSourceNotFound)
	}
	if _, err := tx.Exec(ctx, `UPDATE `+s.schema+`.players SET tier = $2, updated_at = now() WHERE id = $1::uuid`, playerID, tier); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	// Recalculate: baseline pemain itu berubah → full rebuild.
	_, err = s.RebuildAll(ctx)
	return err
}

// AdminDeleteSession — hapus sesi oleh ADMIN: boleh status apa pun (locked
// sekalipun, tidak seperti DELETE /sessions/{id} anon). Rating source ikut
// dibersihkan (rating_events → deltas cascade; rating_sources row) lalu
// FULL REBUILD — transitivity mengharuskan pemain lain yang terpengaruh
// dihitung ulang (alur sama dengan RevertSource). Kembalikan share_code.
func (s *SessionStore) AdminDeleteSession(ctx context.Context, lookup string) (string, error) {
	if strings.TrimSpace(lookup) == "" {
		return "", fmt.Errorf("%w: session lookup must not be blank", ErrValidation)
	}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		return "", err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var rowID, shareCode string
	err = tx.QueryRow(ctx, `
		SELECT s.id::text, s.share_code FROM `+s.schema+`.sessions s
		WHERE s.share_code = $1 OR s.id::text = $1
		ORDER BY (s.share_code = $1) DESC LIMIT 1`, lookup).Scan(&rowID, &shareCode)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", fmt.Errorf("%w: session not found: %s", ErrNotFound, lookup)
	}
	if err != nil {
		return "", err
	}
	// Rating source ikut dihapus (events → deltas cascade; source registry row).
	if _, err := tx.Exec(ctx, `DELETE FROM `+s.schema+`.rating_events WHERE source_id = $1`, shareCode); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM `+s.schema+`.rating_sources WHERE source_id = $1`, shareCode); err != nil {
		return "", err
	}
	// Hapus sesi (child tables: session_players/scheduled_games/dll. cascade).
	if _, err := tx.Exec(ctx, `DELETE FROM `+s.schema+`.sessions WHERE id = $1::uuid`, rowID); err != nil {
		return "", err
	}
	if err := tx.Commit(ctx); err != nil {
		return "", err
	}
	// Transitivitas: pemain yang rating-nya terpengaruh harus dihitung ulang.
	if _, err := s.RebuildAll(ctx); err != nil {
		return "", err
	}
	return shareCode, nil
}

// DeletePlayer — hapus pemain (admin). Hapus data rating dulu (FK), lalu
// panggil fungsi SQL delete_player (cek session refs; force utk paksa).
// Setelah commit: RebuildAll — rating transitif, pemain lain yang W/L-nya
// melibatkan pemain ini harus dihitung ulang (temuan audit 2026-08-19).
func (s *SessionStore) DeletePlayer(ctx context.Context, playerID string, force bool) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// Hapus data rating pemain ini (events ikut cascade deltas)
	if _, err := tx.Exec(ctx, `DELETE FROM `+s.schema+`.rating_events
		WHERE id IN (SELECT event_id FROM `+s.schema+`.rating_deltas WHERE player_id = $1::uuid)`, playerID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM `+s.schema+`.rating_players WHERE player_id = $1::uuid`, playerID); err != nil {
		return err
	}
	// panggil delete_player SQL (session ref check)
	if _, err := tx.Exec(ctx, `SELECT `+s.schema+`.delete_player($1::uuid, $2)`, playerID, force); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	// Transitivitas: pemain lain yang rating-nya terpengaruh harus dihitung ulang.
	_, err = s.RebuildAll(ctx)
	return err
}

// MergeResult — ringkasan merge player.
type MergeResult struct {
	TargetPlayerID string `json:"target_player_id"`
	SourcePlayerID string `json:"source_player_id"`
	AliasesMoved   int    `json:"aliases_moved"`
	SessionsMoved  int    `json:"sessions_moved"`
	DeltasMoved    int    `json:"deltas_moved"`
	SnapshotsMoved int    `json:"snapshots_moved"`
	PairsMoved     int    `json:"pairs_moved"`
	TeamMoves      int    `json:"team_moves"`
}

// MergePlayers — gabungkan `sourceID` ke `targetID` (admin). Semua referensi
// (aliases, session_players, rating_deltas, season snapshots, tournament
// pairs/team) dipindah source → target; baris target yang sudah ada menang.
// Pemain source dihapus. Rating TIDAK di-rebuild di sini — caller (handler)
// harus memanggil RebuildAll supaya rating_players konsisten dengan deltas.
//
// Eksekusi via SQL function SECURITY DEFINER (`schema`.merge_players) — pola
// sama dengan delete_player: majadu_app hanya punya DML grant di sebagian
// tabel, jadi operasi DELETE/INSERT lintas tabel dijalankan sebagai owner
// (qouver). Migration: 000012_merge_players.sql (VPS).
func (s *SessionStore) MergePlayers(ctx context.Context, targetID, sourceID string) (*MergeResult, error) {
	if targetID == sourceID {
		return nil, fmt.Errorf("%w: source and target must be different players", ErrValidation)
	}
	var raw []byte
	err := s.pool.QueryRow(ctx,
		`SELECT `+s.schema+`.merge_players($1::uuid, $2::uuid)`, targetID, sourceID).Scan(&raw)
	if err != nil {
		if strings.Contains(err.Error(), "target player not found") {
			return nil, fmt.Errorf("%w: target player not found", ErrNotFound)
		}
		if strings.Contains(err.Error(), "source player not found") {
			return nil, fmt.Errorf("%w: source player not found", ErrNotFound)
		}
		return nil, err
	}
	var res MergeResult
	if err := json.Unmarshal(raw, &res); err != nil {
		return nil, err
	}
	return &res, nil
}

// AdminDeleteTournament — hapus tournament oleh ADMIN (classic | team):
// rating source ikut dibersihkan (events+deltas, rating_sources) lalu
// FULL REBUILD (transitivitas). Child tables (pairs/groups/matches/team)
// cascade via FK. Kembalikan share_code.
func (s *SessionStore) AdminDeleteTournament(ctx context.Context, lookup string) (string, error) {
	if strings.TrimSpace(lookup) == "" {
		return "", fmt.Errorf("%w: tournament lookup must not be blank", ErrValidation)
	}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		return "", err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var rowID, shareCode string
	err = tx.QueryRow(ctx, `
		SELECT t.id::text, t.share_code FROM `+s.schema+`.tournaments t
		WHERE t.share_code = $1 OR t.id::text = $1
		ORDER BY (t.share_code = $1) DESC LIMIT 1`, lookup).Scan(&rowID, &shareCode)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", fmt.Errorf("%w: tournament not found: %s", ErrNotFound, lookup)
	}
	if err != nil {
		return "", err
	}
	// Rating source ikut dihapus (events → deltas cascade; source registry row).
	if _, err := tx.Exec(ctx, `DELETE FROM `+s.schema+`.rating_events WHERE source_id = $1`, shareCode); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM `+s.schema+`.rating_sources WHERE source_id = $1`, shareCode); err != nil {
		return "", err
	}
	// Hapus tournament (child tables: pairs/groups/matches/team cascade).
	if _, err := tx.Exec(ctx, `DELETE FROM `+s.schema+`.tournaments WHERE id = $1::uuid`, rowID); err != nil {
		return "", err
	}
	if err := tx.Commit(ctx); err != nil {
		return "", err
	}
	// Transitivitas: pemain yang rating-nya terpengaruh harus dihitung ulang.
	if _, err := s.RebuildAll(ctx); err != nil {
		return "", err
	}
	return shareCode, nil
}

// SetPlayerTierOnRegister — set tier induk saat registrasi player baru
// (POST /players optional tier). First-set (tier IS NULL). Validasi 8-tier.
func (s *SessionStore) SetPlayerTierOnRegister(ctx context.Context, playerID, tier string) error {
	if !domain.ValidTier(tier) {
		return fmt.Errorf("%w: tier must be 8-tier (D..A+)", ErrValidation)
	}
	_, err := s.pool.Exec(ctx, `UPDATE `+s.schema+`.players SET tier = $2 WHERE id = $1::uuid AND tier IS NULL`,
		playerID, tier)
	return err
}
