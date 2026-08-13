// Package store — akses data. Write-path session (publish/delete) dijalankan
// langsung di Go dalam satu transaksi (di-port dari bm.publish_session /
// bm.delete_session); read-path tetap memakai fungsi SQL yang tervalidasi
// (get_session, list_sessions).
package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ── Error sentinel ─────────────────────────────────────────────────────────
// Dipetakan ke respons HTTP oleh handler (lihat mapPublishError) — kontrak
// publik error tidak berubah dibanding era fungsi SQL.
var (
	// ErrNotFound — resource tidak ada.
	ErrNotFound = errors.New("not found")
	// ErrLocked — session berstatus non-draft (locked/completed/archived).
	ErrLocked = errors.New("session is locked")
	// ErrVersionMismatch — expected version tidak cocok dengan versi tersimpan.
	ErrVersionMismatch = errors.New("version mismatch")
	// ErrValidation — snapshot gagal validasi / resolve pemain.
	ErrValidation = errors.New("validation failed")
	// ErrContention — sesi sedang di-update request lain (advisory lock / FOR UPDATE NOWAIT).
	ErrContention = errors.New("session is being updated by another request; reload and retry")
)

// SessionStore — akses session.
type SessionStore struct {
	pool *pgxpool.Pool
}

// NewSessionStore — buat SessionStore dengan pool koneksi.
func NewSessionStore(pool *pgxpool.Pool) *SessionStore {
	return &SessionStore{pool: pool}
}

// Load — read-path: get_session(id) → snapshot ter-decode.
func (s *SessionStore) Load(ctx context.Context, id string) (*domain.CloudSnapshot, error) {
	var raw []byte
	err := s.pool.QueryRow(ctx, `SELECT get_session($1)`, id).Scan(&raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	// get_session mengembalikan NULL (bukan no-rows) saat sesi tak ada.
	if raw == nil {
		return nil, ErrNotFound
	}
	snap := &domain.CloudSnapshot{}
	if err := json.Unmarshal(raw, snap); err != nil {
		return nil, fmt.Errorf("decode snapshot: %w", err)
	}
	return snap, nil
}

// Save — publish write-path (port bm.publish_session): satu transaksi berisi
// advisory lock, lock/version check, validasi snapshot, resolve alias pemain,
// lalu sinkronisasi tabel relasional. Setelah commit, snapshot dibaca ulang
// via get_session (read-path tetap satu-satunya sumber bentuk respons).
func (s *SessionStore) Save(ctx context.Context, id string, snap *domain.CloudSnapshot) (*domain.CloudSnapshot, error) {
	if id = strings.TrimSpace(id); id == "" {
		return nil, fmt.Errorf("%w: session id must not be blank", ErrValidation)
	}

	// ── nilai turunan snapshot (mirror awal publish_session) ─────────────
	title := snap.Session.Title
	dateStr := snap.Session.Date // wajib valid — sudah dicek ValidateSnapshot
	startStr := snap.Session.SessionStart
	if startStr == "" {
		startStr = "00:00"
	}
	slotMinutes := snap.Session.SlotMinutes
	if slotMinutes == 0 {
		slotMinutes = 20
	}
	status := "draft"
	if snap.Session.Locked {
		status = "locked"
	}
	includeAbsent := len(snap.AbsentPlayers) > 0

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }() // no-op setelah Commit

	// 1. Advisory lock — mirror pg_try_advisory_xact_lock('bm.publish_session:'||id).
	var locked bool
	if err := tx.QueryRow(ctx,
		`SELECT pg_try_advisory_xact_lock(hashtextextended('bm.publish_session:' || $1, 0))`, id,
	).Scan(&locked); err != nil {
		return nil, err
	}
	if !locked {
		return nil, ErrContention
	}

	// 2. Baca baris sessions FOR UPDATE NOWAIT (mirror SELECT ... FOR UPDATE NOWAIT).
	var (
		rowID         string
		currentVer    int
		currentStatus string
		found         bool
	)
	err = tx.QueryRow(ctx, `
		SELECT s.id::text, s.version, s.status
		FROM sessions s
		WHERE s.share_code = $1 OR s.id::text = $1
		ORDER BY (s.share_code = $1) DESC
		LIMIT 1
		FOR UPDATE NOWAIT`, id).Scan(&rowID, &currentVer, &currentStatus)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		found = false
	case err != nil:
		if isLockNotAvailable(err) {
			return nil, ErrContention
		}
		return nil, err
	default:
		found = true
	}

	// 3. Lock enforcement + version check (mirror baris 1041–1052 SQL).
	expected := snap.Version
	var nextVersion int
	switch {
	case found:
		if currentStatus != "draft" {
			return nil, ErrLocked
		}
		if expected != nil && *expected != currentVer {
			return nil, fmt.Errorf("%w: expected %d, actual %d", ErrVersionMismatch, *expected, currentVer)
		}
		nextVersion = currentVer + 1
	default:
		if expected != nil {
			return nil, fmt.Errorf("%w: expected %d, actual null", ErrVersionMismatch, *expected)
		}
		nextVersion = 1
	}

	// 4. Validasi snapshot (port validate_session_snapshot).
	if err := domain.ValidateSnapshot(snap); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrValidation, err)
	}
	if slotMinutes <= 0 {
		return nil, fmt.Errorf("%w: slotMinutes must be positive for session %s", ErrValidation, id)
	}

	// 5. Resolve alias pemain (mirror baris 1061–1161 SQL).
	resolved, err := resolvePlayerAliases(ctx, tx, snap.Players)
	if err != nil {
		return nil, err
	}

	// 6. Upsert sessions.
	var sessionID string
	if found {
		if _, err := tx.Exec(ctx, `
			UPDATE sessions
			SET title = $2, session_date = $3::date, session_start = $4::time,
			    slot_minutes = $5, session_tier_count = 0, include_tier_count = false,
			    include_absent_players = $6, status = $7, source = 'compat_publish',
			    version = $8, updated_at = now()
			WHERE id = $1::uuid`,
			rowID, title, dateStr, startStr, slotMinutes, includeAbsent, status, nextVersion); err != nil {
			return nil, err
		}
		sessionID = rowID
	} else {
		if err := tx.QueryRow(ctx, `
			INSERT INTO sessions (share_code, title, session_date, session_start,
				slot_minutes, session_tier_count, include_tier_count, include_absent_players,
				status, source, version)
			VALUES ($1, $2, $3::date, $4::time, $5, 0, false, $6, $7, 'compat_publish', $8)
			RETURNING id::text`,
			id, title, dateStr, startStr, slotMinutes, includeAbsent, status, nextVersion).Scan(&sessionID); err != nil {
			return nil, err
		}
	}

	// 7. Sinkronisasi tabel relasional (mirror baris 1162–1390 SQL).
	if err := syncSessionTables(ctx, tx, sessionID, snap, resolved, startStr, slotMinutes); err != nil {
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	// Snapshot hasil publish dibaca dari read-path (get_session) — satu sumber.
	return s.Load(ctx, id)
}

// Delete — delete write-path (port bm.delete_session): tolak non-draft, lalu
// hapus baris sessions — child tables terhapus via ON DELETE CASCADE.
func (s *SessionStore) Delete(ctx context.Context, lookup string) error {
	if strings.TrimSpace(lookup) == "" {
		return fmt.Errorf("%w: session lookup must not be blank", ErrValidation)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var (
		rowID  string
		status string
	)
	err = tx.QueryRow(ctx, `
		SELECT s.id::text, s.status
		FROM sessions s
		WHERE s.share_code = $1 OR s.id::text = $1
		ORDER BY (s.share_code = $1) DESC
		LIMIT 1`, lookup).Scan(&rowID, &status)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return fmt.Errorf("%w: session not found: %s", ErrNotFound, lookup)
	case err != nil:
		return err
	}
	if status != "draft" {
		return fmt.Errorf("%w: cannot delete a locked session; unlock it first", ErrLocked)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM sessions WHERE id = $1::uuid`, rowID); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Unlock — buka kunci session (port bm.unlock_session): status → 'draft',
// version +1. No-op (tanpa bump version) jika sudah draft. Tanpa syarat If-Match
// — mirror fungsi SQL admin yang digantikannya.
func (s *SessionStore) Unlock(ctx context.Context, id string) (*domain.CloudSnapshot, error) {
	if id = strings.TrimSpace(id); id == "" {
		return nil, fmt.Errorf("%w: session id must not be blank", ErrValidation)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var locked bool
	if err := tx.QueryRow(ctx,
		`SELECT pg_try_advisory_xact_lock(hashtextextended('bm.unlock_session:' || $1, 0))`, id,
	).Scan(&locked); err != nil {
		return nil, err
	}
	if !locked {
		return nil, ErrContention
	}

	var (
		rowID   string
		status  string
		version int
	)
	err = tx.QueryRow(ctx, `
		SELECT s.id::text, s.status, s.version
		FROM sessions s
		WHERE s.share_code = $1 OR s.id::text = $1
		ORDER BY (s.share_code = $1) DESC
		LIMIT 1
		FOR UPDATE NOWAIT`, id).Scan(&rowID, &status, &version)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return nil, ErrNotFound
	case err != nil:
		if isLockNotAvailable(err) {
			return nil, ErrContention
		}
		return nil, err
	}

	if status != "draft" {
		if _, err := tx.Exec(ctx, `
			UPDATE sessions SET status = 'draft', version = version + 1, updated_at = now()
			WHERE id = $1::uuid`, rowID); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return s.Load(ctx, id)
}

// RegisterPlayer — registry pemain (register_player SQL). Fungsi SQL TETAP
// dipakai: resolve_tournament_player → publish_tournament (masih SQL) bergantung
// padanya. Satu source of truth — Go tidak punya implementasi kedua.
func (s *SessionStore) RegisterPlayer(ctx context.Context, name, canonicalName string) (string, error) {
	var id string
	err := s.pool.QueryRow(ctx,
		`SELECT register_player($1, $2)`,
		name, canonicalName,
	).Scan(&id)
	return id, err
}

// EnsurePlayersRegistered — daftarkan semua pemain (idempotent) sebelum
// publish pertama, supaya validasi resolve player di write-path lolos.
func (s *SessionStore) EnsurePlayersRegistered(ctx context.Context, players []domain.Player) error {
	for _, p := range players {
		if _, err := s.RegisterPlayer(ctx, p.Name, p.Name); err != nil {
			return fmt.Errorf("register %q: %w", p.Name, err)
		}
	}
	return nil
}

// SessionMeta — baris dari list_sessions() (key JSON sama dengan kontrak RPC).
type SessionMeta struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Date        string `json:"date"`
	PlayerCount int    `json:"player_count"`
	TotalGames  int    `json:"total_games"`
	Locked      bool   `json:"locked"`
}

// ListSessions — read-path: daftar metadata semua session (list_sessions()).
func (s *SessionStore) ListSessions(ctx context.Context) ([]SessionMeta, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id, title, date, player_count, total_games, locked FROM list_sessions()`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]SessionMeta, 0)
	for rows.Next() {
		var m SessionMeta
		if err := rows.Scan(&m.ID, &m.Title, &m.Date, &m.PlayerCount, &m.TotalGames, &m.Locked); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// ── helpers write-path ─────────────────────────────────────────────────────

// playerRef — padanan trim(player.value->>'id') di SQL.
func playerRef(id string) string { return strings.TrimSpace(id) }

// resolvePlayerAliases — resolve tiap pemain snapshot ke player_id via
// player_aliases (normalized name). Mirror baris 1061–1161 SQL: unresolved,
// invalid ref, dan duplicate canonical semuanya ditolak.
// Mengembalikan map player_ref → player_id.
func resolvePlayerAliases(ctx context.Context, tx pgx.Tx, players []domain.Player) (map[string]string, error) {
	resolved := make(map[string]string, len(players)) // player_ref → player_id
	byPlayer := make(map[string]string, len(players)) // player_id → player_ref (deteksi duplikat)

	for _, p := range players {
		ref := playerRef(p.ID)
		norm := domain.NormalizePlayerName(p.Name)
		if norm == "" {
			return nil, fmt.Errorf("%w: unresolved players for session: blank name for ref %q", ErrValidation, ref)
		}
		var pid string
		err := tx.QueryRow(ctx,
			`SELECT player_id::text FROM player_aliases WHERE alias_name = $1`, norm).Scan(&pid)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("%w: unresolved players for session: %q (normalized %q)", ErrValidation, p.Name, norm)
		}
		if err != nil {
			return nil, err
		}
		if prev, ok := byPlayer[pid]; ok && prev != ref {
			return nil, fmt.Errorf("%w: duplicate canonical resolution within session: %q and %q", ErrValidation, prev, ref)
		}
		byPlayer[pid] = ref
		resolved[ref] = pid
	}
	return resolved, nil
}

// syncSessionTables — delete + re-insert child tables (mirror baris 1162–1390 SQL).
// resolved: player_ref → player_id (hasil resolve alias).
func syncSessionTables(ctx context.Context, tx pgx.Tx, sessionID string, snap *domain.CloudSnapshot, resolved map[string]string, startStr string, slotMinutes int) error {
	// Hapus child tables — urutan mirror SQL (FK aman: scheduled_game_players
	// cascade dari scheduled_games, fix_matches.slot_* SET NULL dari session_players).
	if _, err := tx.Exec(ctx, `DELETE FROM scheduled_games WHERE session_id = $1::uuid`, sessionID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM fix_matches WHERE session_id = $1::uuid`, sessionID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM session_players WHERE session_id = $1::uuid`, sessionID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM session_courts WHERE session_id = $1::uuid`, sessionID); err != nil {
		return err
	}

	// ── session_courts (mirror baris 1213–1243) ──────────────────────────
	courtCount := snap.Session.Courts
	if n := len(snap.Session.CourtTimes); n > courtCount {
		courtCount = n
	}
	startTime, _ := time.Parse("15:04", startStr) // sudah valid (default 00:00)
	for ci := 0; ci < courtCount; ci++ {
		courtName := ""
		if ci < len(snap.Session.CourtNames) {
			courtName = snap.Session.CourtNames[ci]
		}
		ctStart, ctEnd := startStr, startStr
		endSet := false
		slots := 1 // slotsPerCourt tidak di-decode — default 1 (mirror key absent)
		if ci < len(snap.Session.CourtTimes) {
			if snap.Session.CourtTimes[ci].Start != "" {
				ctStart = snap.Session.CourtTimes[ci].Start
			}
			if snap.Session.CourtTimes[ci].End != "" {
				ctEnd = snap.Session.CourtTimes[ci].End
				endSet = true
			}
		}
		if !endSet {
			// end default: session_start + slotMinutes * slotsPerCourt
			ctEnd = startTime.Add(time.Duration(slotMinutes*slots) * time.Minute).Format("15:04")
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO session_courts (session_id, court_index, court_name, start_time, end_time)
			VALUES ($1::uuid, $2, $3, $4::time, $5::time)`,
			sessionID, ci, courtName, ctStart, ctEnd); err != nil {
			return err
		}
	}

	// ── session_players (mirror baris 1244–1288) ─────────────────────────
	absentOrder := make(map[string]int, len(snap.AbsentPlayers))
	for i, ref := range snap.AbsentPlayers {
		absentOrder[playerRef(ref)] = i
	}
	playerInternal := make(map[string]string, len(snap.Players)) // player_ref → internal_id
	for i, p := range snap.Players {
		ref := playerRef(p.ID)
		ao, isAbsent := absentOrder[ref]
		if !isAbsent {
			ao = -1 // NULL
		}
		var internalID string
		if err := tx.QueryRow(ctx, `
			INSERT INTO session_players
				(session_id, player_id, player_ref, source_name, sort_order, absent_order, gender, tier, is_absent)
			VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, $7, $8, $9)
			RETURNING internal_id::text`,
			sessionID, resolved[ref], ref, p.Name, i, nilableInt(ao), p.Gender, p.Tier, isAbsent).Scan(&internalID); err != nil {
			return err
		}
		playerInternal[ref] = internalID
	}

	// ── fix_matches (mirror baris 1289–1321) ─────────────────────────────
	fixIDs := make(map[string]string, len(snap.FixMatches)) // legacy_ref → internal_id
	for i, fm := range snap.FixMatches {
		legacyRef := fm.ID
		if legacyRef == "" {
			legacyRef = fmt.Sprintf("fix-%d", i)
		}
		var internalID string
		if err := tx.QueryRow(ctx, `
			INSERT INTO fix_matches (session_id, legacy_ref, sort_order)
			VALUES ($1::uuid, $2, $3)
			RETURNING internal_id::text`,
			sessionID, legacyRef, i).Scan(&internalID); err != nil {
			return err
		}
		fixIDs[legacyRef] = internalID
	}
	for i, fm := range snap.FixMatches {
		legacyRef := fm.ID
		if legacyRef == "" {
			legacyRef = fmt.Sprintf("fix-%d", i)
		}
		for slotIdx := 0; slotIdx < 4 && slotIdx < len(fm.Slots); slotIdx++ {
			if fm.Slots[slotIdx] == nil {
				continue
			}
			ref := playerRef(*fm.Slots[slotIdx])
			spID, ok := playerInternal[ref]
			if !ok {
				continue // slot mengacu pemain tak dikenal — lolos (SQL pakai inner join)
			}
			if _, err := tx.Exec(ctx, fmt.Sprintf(`
				UPDATE fix_matches SET slot_%d = $1::uuid WHERE internal_id = $2::uuid`,
				slotIdx), spID, fixIDs[legacyRef]); err != nil {
				return err
			}
		}
	}

	// ── scheduled_games (mirror baris 1322–1354) ─────────────────────────
	gameInternal := make(map[string]string, len(snap.Schedule)) // "slot-court" → internal_id
	playedSet := make(map[string]struct{}, len(snap.PlayedGames))
	for _, k := range snap.PlayedGames {
		playedSet[k] = struct{}{}
	}
	for i, g := range snap.Schedule {
		key := domain.GameKey(g.Slot, g.Court)
		_, isPlayed := playedSet[key]
		status := "scheduled"
		if isPlayed {
			status = "played"
		}
		var internalID string
		if err := tx.QueryRow(ctx, `
			INSERT INTO scheduled_games
				(session_id, legacy_order, slot_index, court_index, status, source, is_played, played_order)
			VALUES ($1::uuid, $2, $3, $4, $5, 'compat_publish', $6, $7)
			RETURNING internal_id::text`,
			sessionID, i, g.Slot, g.Court, status, isPlayed, nilableInt(playedOrder(i, isPlayed))).Scan(&internalID); err != nil {
			return err
		}
		gameInternal[key] = internalID
	}

	// ── scheduled_game_players (mirror baris 1355–1383) ──────────────────
	for _, g := range snap.Schedule {
		key := domain.GameKey(g.Slot, g.Court)
		gameID := gameInternal[key]
		type member struct {
			team string
			pos  int
			ref  string
		}
		members := []member{
			{"A", 0, g.TeamA[0]}, {"A", 1, g.TeamA[1]},
			{"B", 0, g.TeamB[0]}, {"B", 1, g.TeamB[1]},
		}
		for _, m := range members {
			spID, ok := playerInternal[playerRef(m.ref)]
			if !ok {
				continue // tak mungkin setelah validasi, tapi jangan crash
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO scheduled_game_players
					(scheduled_game_internal_id, session_player_internal_id, team, position)
				VALUES ($1::uuid, $2::uuid, $3, $4)`,
				gameID, spID, m.team, m.pos); err != nil {
				return err
			}
		}
	}

	// ── gameScores → score_a/score_b (mirror baris 1384–1390) ────────────
	for key, score := range snap.GameScores {
		slot, court, ok := splitGameKey(key)
		if !ok {
			continue // tak mungkin setelah validasi, tapi jangan crash
		}
		if _, err := tx.Exec(ctx, `
			UPDATE scheduled_games SET score_a = $2, score_b = $3
			WHERE session_id = $1::uuid AND slot_index = $4 AND court_index = $5`,
			sessionID, score.A, score.B, slot, court); err != nil {
			return err
		}
	}
	return nil
}

// nilableInt — int ≥ 0 dikirim apa adanya, -1 → NULL (absent_order/played_order).
func nilableInt(n int) *int {
	if n < 0 {
		return nil
	}
	return &n
}

// playedOrder — played_order = legacy_order + 1 saat game played (mirror SQL).
func playedOrder(legacyOrder int, isPlayed bool) int {
	if !isPlayed {
		return -1 // NULL
	}
	return legacyOrder + 1
}

// splitGameKey — pecah "slot-court". Mengembalikan slot, court, dan ok.
func splitGameKey(key string) (int, int, bool) {
	parts := strings.SplitN(key, "-", 2)
	if len(parts) != 2 {
		return 0, 0, false
	}
	var slot, court int
	if _, err := fmt.Sscanf(parts[0], "%d", &slot); err != nil {
		return 0, 0, false
	}
	if _, err := fmt.Sscanf(parts[1], "%d", &court); err != nil {
		return 0, 0, false
	}
	return slot, court, true
}

// isLockNotAvailable — deteksi SQLSTATE 55P03 (lock_not_available).
func isLockNotAvailable(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "55P03"
}
