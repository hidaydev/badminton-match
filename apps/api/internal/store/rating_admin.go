package store

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
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

// RebaselinePlayer — POST /ratings/players/{id}/rebaseline (admin): set
// rating = mid kelas assigned LANGSUNG, TANPA rebuild (rebuild menimpa
// rating manual dari events — RATING_TIERING_REVAMP §8 P3 #11). Ingest
// berikutnya melanjutkan dari baseline baru secara alami.
// Catatan: bersifat "lunak" — hilang saat RebuildAll/reset season berikutnya.
func (s *SessionStore) RebaselinePlayer(ctx context.Context, playerID string) error {
	cfg, err := s.LoadRatingConfig(ctx, false)
	if err != nil {
		return err
	}
	var class *string
	var peak float64
	err = s.pool.QueryRow(ctx, `
		SELECT class, peak_rating FROM `+s.schema+`.rating_players
		WHERE player_id = $1::uuid`, playerID).Scan(&class, &peak)
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("%w: player not rated", ErrSourceNotFound)
	}
	if err != nil {
		return err
	}
	if class == nil || *class == "" {
		return fmt.Errorf("%w: player has no assigned class", ErrValidation)
	}
	mid, ok := cfg.MidRatingForClass(*class)
	if !ok {
		return fmt.Errorf("%w: unknown class %q", ErrValidation, *class)
	}
	newPeak := peak
	if mid > newPeak {
		newPeak = mid
	}
	_, err = s.pool.Exec(ctx, `
		UPDATE `+s.schema+`.rating_players
		SET rating = $2, peak_rating = $3, updated_at = now()
		WHERE player_id = $1::uuid`, playerID, mid, newPeak)
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
// (POST /players optional tier). First-set (tier IS NULL).
func (s *SessionStore) SetPlayerTierOnRegister(ctx context.Context, playerID, tier string) error {
	if tier != "A" && tier != "B" && tier != "C" && tier != "D" {
		return fmt.Errorf("%w: tier must be A/B/C/D", ErrValidation)
	}
	_, err := s.pool.Exec(ctx, `UPDATE `+s.schema+`.players SET tier = $2 WHERE id = $1::uuid AND tier IS NULL`,
		playerID, tier)
	return err
}
