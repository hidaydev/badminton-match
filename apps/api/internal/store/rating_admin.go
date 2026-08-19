package store

import (
	"context"
	"fmt"

	"majadu-api/internal/domain"
)

// ── Admin: tier induk, class rating, delete player (ADMIN_MENU_PLAN.md §3.3-3.4) ──

// SetPlayerTier — ubah tier induk (STICKY, admin-only). RATING_TIERING_REVAMP
// §2.5.2: mengubah tier → update class rating (source='admin') + recalculate
// (RebuildAll) supaya baseline forming berubah.
func (s *SessionStore) SetPlayerTier(ctx context.Context, playerID, tier string) error {
	if tier != "A" && tier != "B" && tier != "C" && tier != "D" {
		return fmt.Errorf("%w: tier must be A/B/C/D", ErrValidation)
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
	if _, err := tx.Exec(ctx, `UPDATE `+s.schema+`.players SET tier = $2 WHERE id = $1::uuid`, playerID, tier); err != nil {
		return err
	}
	// Class rating ikut (Q3): source='admin', baseline forming baru.
	if _, err := tx.Exec(ctx, `
		UPDATE `+s.schema+`.rating_players SET class = $2, class_source = 'admin' WHERE player_id = $1::uuid`,
		playerID, tier); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	// Recalculate: baseline pemain itu berubah → full rebuild.
	_, err = s.RebuildAll(ctx)
	return err
}

// SetPlayerClass — ubah class rating (12 sub-tier) langsung (admin).
// Floor berubah; TIDAK rebuild (class bukan input Glicko).
func (s *SessionStore) SetPlayerClass(ctx context.Context, playerID, class string) error {
	if !domain.ValidClass(class) {
		return fmt.Errorf("%w: class must be 12 sub-tier (D-..A+)", ErrValidation)
	}
	tag, err := s.pool.Exec(ctx, `
		UPDATE `+s.schema+`.rating_players SET class = $2, class_source = 'admin'
		WHERE player_id = $1::uuid`, playerID, class)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("%w: player not rated", ErrSourceNotFound)
	}
	return nil
}

// DeletePlayer — hapus pemain (admin). Hapus data rating dulu (FK), lalu
// panggil fungsi SQL delete_player (cek session refs; force utk paksa).
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
	return tx.Commit(ctx)
}

// SetPlayerTierOnRegister — set tier induk saat registrasi player baru
// (POST /players optional tier). First-set (tier IS NULL).
func (s *SessionStore) SetPlayerTierOnRegister(ctx context.Context, playerID, tier string) error {
	if tier != "A" && tier != "B" && tier != "C" && tier != "D" {
		return fmt.Errorf("%w: tier must be A/B/C/D", ErrValidation)
	}
	_, err := s.pool.Exec(ctx, `UPDATE `+s.schema+`.players SET tier = $2 WHERE id = $1::uuid AND tier IS NULL`,
		playerID, tier)
	return err
}
