// Package store — akses data. Write-path session (publish/delete/unlock)
// dijalankan langsung di Go dalam satu transaksi; read-path session/player
// juga di Go (rebuild snapshot dari tabel relasional).
package store

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
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
	// schema — nama schema aktif (MAJADU_DB_SCHEMA: bm / bm_dev). Dipakai
	// sebagai namespace kunci advisory lock mengikuti konvensi per-env.
	schema   string
	mu       sync.RWMutex
	watchers map[string]map[chan *domain.CloudSnapshot]struct{}
}

// NewSessionStore — buat SessionStore dengan pool koneksi + schema aktif.
// Schema (bukan hardcode) menentukan namespace kunci advisory lock:
// dev → "bm_dev.publish_session:...", prod → "bm.publish_session:...".
func NewSessionStore(pool *pgxpool.Pool, schema string) *SessionStore {
	return &SessionStore{
		pool:     pool,
		schema:   schema,
		watchers: make(map[string]map[chan *domain.CloudSnapshot]struct{}),
	}
}

// Subscribe — daftar untuk SSE watch pada session id. Kembalikan channel dan cancel func.
func (s *SessionStore) Subscribe(id string) (chan *domain.CloudSnapshot, func()) {
	ch := make(chan *domain.CloudSnapshot, 4)
	s.mu.Lock()
	if s.watchers[id] == nil {
		s.watchers[id] = make(map[chan *domain.CloudSnapshot]struct{})
	}
	s.watchers[id][ch] = struct{}{}
	s.mu.Unlock()
	cancel := func() { s.Unsubscribe(id, ch) }
	return ch, cancel
}

// Unsubscribe — hapus subscriber dan tutup channel.
func (s *SessionStore) Unsubscribe(id string, ch chan *domain.CloudSnapshot) {
	s.mu.Lock()
	if m, ok := s.watchers[id]; ok {
		delete(m, ch)
		if len(m) == 0 {
			delete(s.watchers, id)
		}
	}
	s.mu.Unlock()
	// Close di luar lock biar tidak deadlock jika ada Broadcast yang hold RLock
	// dan coba kirim ke chan yang baru dihapus (select default sudah non-blocking).
	// Close hanya sekali — Unsubscribe dipanggil sekali per Subscribe via defer.
	func() {
		defer func() { _ = recover() }() // jika sudah close
		close(ch)
	}()
}

// Broadcast — kirim snapshot baru ke semua subscriber session id. Non-blocking (slow client drop).
func (s *SessionStore) Broadcast(id string, snap *domain.CloudSnapshot) {
	s.mu.RLock()
	m, ok := s.watchers[id]
	if !ok {
		s.mu.RUnlock()
		return
	}
	// Copy chans biar tidak hold lock saat send (hindari deadlock close)
	chans := make([]chan *domain.CloudSnapshot, 0, len(m))
	for ch := range m {
		chans = append(chans, ch)
	}
	s.mu.RUnlock()
	for _, ch := range chans {
		select {
		case ch <- snap:
		default:
			// buffer penuh → drop (client akan dapat snapshot terbaru di next broadcast)
		}
	}
}

// Load — read-path (port bm.get_session + get_session_snapshot_compat):
// rebuild CloudSnapshot langsung dari tabel relasional dalam Go. Hasilnya
// identik dengan kontrak JSON lama (versi di-merge di level atas).
func (s *SessionStore) Load(ctx context.Context, id string) (*domain.CloudSnapshot, error) {
	if id = strings.TrimSpace(id); id == "" {
		return nil, ErrNotFound
	}

	// Read-only transaction untuk snapshot isolation — mencegah inconsistent
	// reads saat concurrent Save() menghapus + insert ulang child tables (L6 fix).
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// Set read-only after begin (pgx doesn't support ReadOnly in TxOptions directly)
	if _, err := tx.Exec(ctx, `SET TRANSACTION READ ONLY`); err != nil {
		_ = tx.Rollback(ctx)
		return nil, err
	}

	// Resolve lookup (share_code atau uuid) — mirror resolve_session_lookup.
	var sessionID string
	err = tx.QueryRow(ctx, `
		SELECT s.id::text FROM sessions s
		WHERE s.share_code = $1 OR s.id::text = $1
		ORDER BY (s.share_code = $1) DESC
		LIMIT 1`, id).Scan(&sessionID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}

	// ── baris sessions ───────────────────────────────────────────────────
	var (
		title         string
		dateStr       time.Time
		startTime     time.Time
		slotMinutes   int
		status        string
		version       int
		includeAbsent bool
	)
	if err := tx.QueryRow(ctx, `
		SELECT title, session_date, session_start, slot_minutes, status, version, include_absent_players
		FROM sessions WHERE id = $1::uuid`, sessionID).
		Scan(&title, &dateStr, &startTime, &slotMinutes, &status, &version, &includeAbsent); err != nil {
		return nil, err
	}

	// ── courts (+ game_count per court) ──────────────────────────────────
	type courtRow struct {
		index     int
		name      string
		start     time.Time
		end       time.Time
		gameCount int
	}
	courts := []courtRow{}
	rows, err := tx.Query(ctx, `
		SELECT sc.court_index, sc.court_name, sc.start_time, sc.end_time, coalesce(gc.game_count, 0)
		FROM session_courts sc
		LEFT JOIN (
			SELECT sg.session_id, sg.court_index, count(*)::integer AS game_count
			FROM scheduled_games sg GROUP BY sg.session_id, sg.court_index
		) gc ON gc.session_id = sc.session_id AND gc.court_index = sc.court_index
		WHERE sc.session_id = $1::uuid
		ORDER BY sc.court_index`, sessionID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var c courtRow
		if err := rows.Scan(&c.index, &c.name, &c.start, &c.end, &c.gameCount); err != nil {
			rows.Close()
			return nil, err
		}
		courts = append(courts, c)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// ── players ──────────────────────────────────────────────────────────
	type playerRow struct {
		internalID string
		ref        string
		name       string
		gender     string
		tier       int
		isAbsent   bool
		absentOrd  *int
	}
	players := []playerRow{}
	internalToRef := map[string]string{}
	rows, err = tx.Query(ctx, `
		SELECT sp.internal_id::text, sp.player_ref, sp.source_name, sp.gender, sp.tier, sp.is_absent, sp.absent_order
		FROM session_players sp
		WHERE sp.session_id = $1::uuid
		ORDER BY sp.sort_order`, sessionID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var p playerRow
		if err := rows.Scan(&p.internalID, &p.ref, &p.name, &p.gender, &p.tier, &p.isAbsent, &p.absentOrd); err != nil {
			rows.Close()
			return nil, err
		}
		players = append(players, p)
		internalToRef[p.internalID] = p.ref
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// ── fixMatches (slot internal_id → player_ref; null → "") ────────────
	type fixRow struct {
		legacyRef string
		slots     [4]*string
	}
	fixRows := []fixRow{}
	rows, err = tx.Query(ctx, `
		SELECT fm.legacy_ref, fm.slot_0, fm.slot_1, fm.slot_2, fm.slot_3
		FROM fix_matches fm
		WHERE fm.session_id = $1::uuid
		ORDER BY fm.sort_order`, sessionID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var f fixRow
		if err := rows.Scan(&f.legacyRef, &f.slots[0], &f.slots[1], &f.slots[2], &f.slots[3]); err != nil {
			rows.Close()
			return nil, err
		}
		fixRows = append(fixRows, f)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// ── games + game players ─────────────────────────────────────────────
	type gameRow struct {
		internalID string
		legacyOrd  int
		slot       int
		court      int
		isPlayed   bool
		playedOrd  *int
		scoreA     *int
		scoreB     *int
		teamA      [2]string
		teamB      [2]string
	}
	games := []gameRow{}
	gameIdx := map[string]int{} // internal_id → index di games
	rows, err = tx.Query(ctx, `
		SELECT sg.internal_id::text, sg.legacy_order, sg.slot_index, sg.court_index,
		       sg.is_played, sg.played_order, sg.score_a, sg.score_b
		FROM scheduled_games sg
		WHERE sg.session_id = $1::uuid
		ORDER BY sg.legacy_order`, sessionID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var g gameRow
		if err := rows.Scan(&g.internalID, &g.legacyOrd, &g.slot, &g.court, &g.isPlayed, &g.playedOrd, &g.scoreA, &g.scoreB); err != nil {
			rows.Close()
			return nil, err
		}
		gameIdx[g.internalID] = len(games)
		games = append(games, g)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// team members (ref, team, position) — mirror jsonb_agg ... order by position
	rows, err = tx.Query(ctx, `
		SELECT sgp.scheduled_game_internal_id::text, sgp.team, sgp.position, sp.player_ref
		FROM scheduled_game_players sgp
		JOIN session_players sp ON sp.internal_id = sgp.session_player_internal_id
		JOIN scheduled_games sg ON sg.internal_id = sgp.scheduled_game_internal_id
		WHERE sg.session_id = $1::uuid`, sessionID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var (
			gameID, team, ref string
			position          int
		)
		if err := rows.Scan(&gameID, &team, &position, &ref); err != nil {
			rows.Close()
			return nil, err
		}
		gi, ok := gameIdx[gameID]
		if !ok || position < 0 || position > 1 {
			continue
		}
		if team == "A" {
			games[gi].teamA[position] = ref
		} else {
			games[gi].teamB[position] = ref
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// ── assemble CloudSnapshot ───────────────────────────────────────────
	snap := &domain.CloudSnapshot{
		Version: &version,
		Session: domain.SessionConfig{
			Title:        title,
			Date:         dateStr.Format("2006-01-02"),
			Courts:       len(courts),
			SessionStart: startTime.Format("15:04"),
			SlotMinutes:  slotMinutes,
			PlayerCount:  len(players),
			Locked:       status != "draft",
		},
		Players:     []domain.Player{},
		FixMatches:  []domain.FixMatch{},
		Schedule:    []domain.ScheduleSlot{},
		PlayedGames: []string{},
		GameScores:  map[string]domain.GameScore{},
	}
	// courtNames: mirror SQL — hanya di-emit kalau ada nama non-kosong; kalau
	// semua kosong → [] (bukan array string kosong).
	anyCourtName := false
	for _, c := range courts {
		if c.name != "" {
			anyCourtName = true
			break
		}
	}
	for _, c := range courts {
		snap.Session.CourtTimes = append(snap.Session.CourtTimes, domain.CourtTime{
			Start: c.start.Format("15:04"),
			End:   c.end.Format("15:04"),
		})
		if anyCourtName {
			snap.Session.CourtNames = append(snap.Session.CourtNames, c.name)
		}
	}
	type absentEntry struct {
		ref       string
		absentOrd int
		sortOrd   int
	}
	absent := []absentEntry{}
	for i, p := range players {
		snap.Players = append(snap.Players, domain.Player{
			ID:     p.ref,
			Name:   p.name,
			Gender: p.gender,
			Tier:   p.tier,
		})
		if includeAbsent && p.isAbsent {
			ao := 0
			if p.absentOrd != nil {
				ao = *p.absentOrd
			}
			absent = append(absent, absentEntry{ref: p.ref, absentOrd: ao, sortOrd: i})
		}
	}
	sort.Slice(absent, func(i, j int) bool {
		if absent[i].absentOrd != absent[j].absentOrd {
			return absent[i].absentOrd < absent[j].absentOrd
		}
		return absent[i].sortOrd < absent[j].sortOrd
	})
	for _, a := range absent {
		snap.AbsentPlayers = append(snap.AbsentPlayers, a.ref)
	}

	for _, f := range fixRows {
		slots := [4]*string{}
		for i := 0; i < 4; i++ {
			// Mirror SQL coalesce(player_ref, ''): slot kosong → "" (bukan
			// null), supaya kontrak JSON identik dengan era get_session.
			empty := ""
			slots[i] = &empty
			if f.slots[i] != nil {
				if ref, ok := internalToRef[*f.slots[i]]; ok {
					slots[i] = &ref
				}
			}
		}
		snap.FixMatches = append(snap.FixMatches, domain.FixMatch{ID: f.legacyRef, Slots: slots})
	}
	for _, g := range games {
		snap.Schedule = append(snap.Schedule, domain.ScheduleSlot{
			Slot:  g.slot,
			Court: g.court,
			TeamA: g.teamA,
			TeamB: g.teamB,
		})
		key := domain.GameKey(g.slot, g.court)
		if g.isPlayed && g.playedOrd != nil {
			snap.PlayedGames = append(snap.PlayedGames, key)
		}
		if g.scoreA != nil && g.scoreB != nil {
			snap.GameScores[key] = domain.GameScore{A: *g.scoreA, B: *g.scoreB}
		}
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

	// 1. Advisory lock — namespace = schema aktif dari config (bm / bm_dev),
	//    mengikuti konvensi per-env. Kunci identik untuk id yang sama dalam
	//    satu env; berbeda antar env (dev/prod tidak saling memblokir).
	var locked bool
	if err := tx.QueryRow(ctx,
		`SELECT pg_try_advisory_xact_lock(hashtextextended($1 || ':' || $2, 0))`,
		s.schema+".publish_session", id,
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

	// 5b. First-set tier induk STICKY + registered_at (RATING_TIERING_REVAMP §2.5.2).
	//     Hanya diisi kalau players.tier IS NULL (registrasi pertama). Tier/tanggal
	//     dari sesi ini = baseline forming rating; tidak pernah diubah otomatis.
	if err := s.firstSetPlayerTier(ctx, tx, snap.Players, snap.Session.Date); err != nil {
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

	// 8. Auto-lock: semua skor terisi ATAU tanggal lewat → lock otomatis.
	// Version tetap nextVersion (SATU bump per save) — sebelumnya di-increment
	// lagi (double bump n+1→n+2) bikin FE cache (n) kena 40001 di mutasi
	// berikutnya padahal lock yang menolak (audit RC2).
	if currentStatus == "draft" && status == "draft" {
		allScored := len(snap.Schedule) > 0 && countScoredGames(snap) == len(snap.Schedule)
		pastDate := false
		// Compare against WIB date (Asia/Jakarta) — venue selalu WIB.
		// DB current_date pakai UTC (container UTC) → sesi hari-H ke-lock prematur jam 07:00 WIB.
		var today string
		if err := tx.QueryRow(ctx, `SELECT (now() AT TIME ZONE 'Asia/Jakarta')::date::text`).Scan(&today); err == nil {
			pastDate = snap.Session.Date < today
		}
		if allScored || pastDate {
			if _, err := tx.Exec(ctx, `
				UPDATE sessions SET status = 'locked', version = $2, updated_at = now()
				WHERE id = $1::uuid`, rowID, nextVersion); err != nil {
				return nil, err
			}
			status = "locked"
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	// Snapshot hasil publish dibaca dari read-path (get_session) — satu sumber.
	snapOut, err := s.Load(ctx, id)
	if err == nil && snapOut != nil {
		s.Broadcast(id, snapOut)
	}
	return snapOut, err
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
		LIMIT 1
		FOR UPDATE NOWAIT`, lookup).Scan(&rowID, &status)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return fmt.Errorf("%w: session not found: %s", ErrNotFound, lookup)
	case err != nil:
		if isLockNotAvailable(err) {
			return ErrContention
		}
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
		`SELECT pg_try_advisory_xact_lock(hashtextextended($1 || ':' || $2, 0))`,
		s.schema+".unlock_session", id,
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
	out, err := s.Load(ctx, id)
	// Broadcast ke SSE watcher — tanpa ini client yang sedang membuka sesi
	// tidak dapat update status unlocked dan harus manual refresh (bug #2 RC-B).
	if err == nil && out != nil {
		s.Broadcast(id, out)
	}
	return out, err
}

// EnsurePlayersRegistered — daftarkan semua pemain (idempotent, TOCTOU-safe)
// sebelum publish, supaya validasi resolve player di write-path lolos.
// Satu transaksi untuk semua pemain (port bm.register_player — fungsi SQL
// sudah pensiun; lihat registerPlayerInTx).
func (s *SessionStore) EnsurePlayersRegistered(ctx context.Context, players []domain.Player) error {
	if len(players) == 0 {
		return nil
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	for _, p := range players {
		// Placeholder (free/tbd/dst — ABSENT_TBD_PLAYERS_DESIGN.md §5) tidak
		// diregistrasi ke players/aliases.
		if domain.IsPlaceholderName(p.Name) {
			continue
		}
		if _, err := registerPlayerInTx(ctx, tx, p.Name, p.Name, p.Gender); err != nil {
			return fmt.Errorf("register %q: %w", p.Name, err)
		}
	}
	return tx.Commit(ctx)
}

// AutoLockExpiredSessions — sesi draft yang tanggalnya sudah lewat otomatis
// di-lock (ABSENT_TBD_PLAYERS_DESIGN.md §4.6). Dipanggil berkala oleh ticker
// di main.go. Idempotent; hanya menyentuh status='draft' AND session_date < today WIB.
// Version di-bump agar konsisten dengan save-path auto-lock (audit M2 fix).
// Setiap sesi yang di-lock di-broadcast ke SSE watcher (bug #2 RC-B) supaya
// client yang sedang membuka sesi langsung melihat status locked.
func (s *SessionStore) AutoLockExpiredSessions(ctx context.Context) (int64, error) {
	rows, err := s.pool.Query(ctx, `
		UPDATE sessions SET status = 'locked', version = version + 1, updated_at = now()
		WHERE status = 'draft' AND session_date < (now() AT TIME ZONE 'Asia/Jakarta')::date
		RETURNING share_code`)
	if err != nil {
		return 0, err
	}
	defer rows.Close()

	var locked []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return 0, err
		}
		locked = append(locked, id)
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	if len(locked) > 0 {
		// Broadcast di luar transaksi — Load() bikin tx read-only sendiri.
		for _, id := range locked {
			if snap, err := s.Load(ctx, id); err == nil && snap != nil {
				s.Broadcast(id, snap)
			}
		}
	}
	return int64(len(locked)), nil
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

// ListSessions — read-path (port bm.list_sessions): metadata semua session
// (share_code, title, date, player_count, total_games, locked).
func (s *SessionStore) ListSessions(ctx context.Context) ([]SessionMeta, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT s.share_code, s.title, s.session_date::text,
		       coalesce(pc.player_count, 0), coalesce(gc.total_games, 0),
		       (s.status <> 'draft') AS locked
		FROM sessions s
		LEFT JOIN (
			SELECT sp.session_id, count(*)::integer AS player_count
			FROM session_players sp GROUP BY sp.session_id
		) pc ON pc.session_id = s.id
		LEFT JOIN (
			SELECT sg.session_id, count(*)::integer AS total_games
			FROM scheduled_games sg GROUP BY sg.session_id
		) gc ON gc.session_id = s.id
		ORDER BY s.session_date DESC, s.updated_at DESC`)
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

// firstSetPlayerTier — set players.tier + registered_at HANYA untuk pemain yang
// belum punya tier (registrasi pertama). STICKY: tidak pernah menimpa tier existing.
// Snapshot Player.tier (numeric 1-8, TIER_8_UNIFICATION) → text 8-tier.
func (s *SessionStore) firstSetPlayerTier(ctx context.Context, tx pgx.Tx, players []domain.Player, sessionDate string) error {
	if sessionDate == "" {
		return nil
	}
	for _, p := range players {
		if domain.IsPlaceholderName(p.Name) || p.Tier < 1 || p.Tier > 8 {
			continue
		}
		// Resolve nama → player_id (alias). Placeholder di-skip.
		pid, ok, err := resolveTournamentPlayer(ctx, tx, p.Name)
		if err != nil {
			return err
		}
		if !ok {
			continue
		}
		tierText := [...]string{"", "D", "D+", "C", "C+", "B", "B+", "A", "A+"}[p.Tier]
		if _, err := tx.Exec(ctx, `
			UPDATE `+s.schema+`.players
			SET tier = $2, registered_at = $3::date
			WHERE id = $1::uuid AND tier IS NULL`,
			pid, tierText, sessionDate); err != nil {
			return err
		}
	}
	return nil
}

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
		// Placeholder → player_id NULL (resolved[ref] = ""), tanpa resolve alias.
		if domain.IsPlaceholderName(p.Name) {
			resolved[ref] = ""
			continue
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
			sessionID, nilableString(resolved[ref]), ref, p.Name, i, nilableInt(ao), p.Gender, p.Tier, isAbsent).Scan(&internalID); err != nil {
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

// splitGameKey — pecah "slot-court". STRICT: kedua bagian harus digit murni
// (tanpa spasi, tanpa tanda negatif) — Sscanf terlalu lenient (menerima
// " 0-0" dan "0--1" → court negatif). Dipakai granular path, jadi malformed
// key harus ditolak, bukan di-normalisasi.
func splitGameKey(key string) (int, int, bool) {
	parts := strings.SplitN(key, "-", 2)
	if len(parts) != 2 {
		return 0, 0, false
	}
	slot, ok1 := parseUintStrict(parts[0])
	court, ok2 := parseUintStrict(parts[1])
	if !ok1 || !ok2 {
		return 0, 0, false
	}
	return slot, court, true
}

// parseUintStrict — parse non-negative integer dari string digit murni.
func parseUintStrict(s string) (int, bool) {
	if s == "" {
		return 0, false
	}
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int(c-'0')
		if n > 1<<30 { // guard overflow
			return 0, false
		}
	}
	return n, true
}

// isLockNotAvailable — deteksi SQLSTATE 55P03 (lock_not_available).
func isLockNotAvailable(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "55P03"
}

// countScoredGames — hitung jumlah game yang sudah punya skor di snapshot.
func countScoredGames(snap *domain.CloudSnapshot) int {
	count := 0
	for _, g := range snap.Schedule {
		key := domain.GameKey(g.Slot, g.Court)
		if _, ok := snap.GameScores[key]; ok {
			count++
		}
	}
	return count
}
