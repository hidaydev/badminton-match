// Read-path: rebuild CloudSnapshot dari tabel relasional (Load).

package store

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
)

// Load — read-path (port bm.get_session + get_session_snapshot_compat):
// rebuild CloudSnapshot langsung dari tabel relasional dalam Go. Hasilnya
// identik dengan kontrak JSON lama (versi di-merge di level atas).
func (s *SessionStore) Load(ctx context.Context, id string) (*domain.CloudSnapshot, error) {
	if id = strings.TrimSpace(id); id == "" {
		return nil, ErrNotFound
	}

	// Read-only transaction untuk snapshot isolation — mencegah inconsistent
	// reads saat concurrent Save() menghapus + insert ulang child tables (L6 fix).
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

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
		SELECT sp.internal_id::text, sp.player_ref,
		       COALESCE(p.canonical_name, sp.source_name),
		       sp.gender, sp.tier, sp.is_absent, sp.absent_order
		FROM session_players sp
		LEFT JOIN players p ON p.id = sp.player_id
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
		skipped    []string
	}
	games := []gameRow{}
	gameIdx := map[string]int{} // internal_id → index di games

	// Baca scheduled_games, dengan fallback bila kolom skipped_player_refs
	// belum ada (migration 000014 belum apply). hasSkippedCol menandai bentuk
	// baris yang dipakai; scan menyesuaikan.
	hasSkippedCol := true
	rows, err = tx.Query(ctx, `
		SELECT sg.internal_id::text, sg.legacy_order, sg.slot_index, sg.court_index,
		       sg.is_played, sg.played_order, sg.score_a, sg.score_b,
		       COALESCE(sg.skipped_player_refs, '{}')
		FROM scheduled_games sg
		WHERE sg.session_id = $1::uuid
		ORDER BY sg.legacy_order`, sessionID)
	if err != nil && isSkippedColumnMissing(err) {
		hasSkippedCol = false
		rows, err = tx.Query(ctx, `
			SELECT sg.internal_id::text, sg.legacy_order, sg.slot_index, sg.court_index,
			       sg.is_played, sg.played_order, sg.score_a, sg.score_b
			FROM scheduled_games sg
			WHERE sg.session_id = $1::uuid
			ORDER BY sg.legacy_order`, sessionID)
	}
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var g gameRow
		if hasSkippedCol {
			var skipped []string
			if err := rows.Scan(&g.internalID, &g.legacyOrd, &g.slot, &g.court, &g.isPlayed, &g.playedOrd, &g.scoreA, &g.scoreB, &skipped); err != nil {
				rows.Close()
				return nil, err
			}
			if skipped == nil {
				skipped = []string{}
			}
			g.skipped = skipped
		} else {
			if err := rows.Scan(&g.internalID, &g.legacyOrd, &g.slot, &g.court, &g.isPlayed, &g.playedOrd, &g.scoreA, &g.scoreB); err != nil {
				rows.Close()
				return nil, err
			}
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
		if len(g.skipped) > 0 {
			if snap.SkippedPlayers == nil {
				snap.SkippedPlayers = map[string][]string{}
			}
			cp := make([]string, len(g.skipped))
			copy(cp, g.skipped)
			snap.SkippedPlayers[key] = cp
		}
	}
	return snap, nil
}

// isSkippedColumnMissing — alias historis: kolom skipped_player_refs hilang
// (SQLSTATE 42703). Delegasi ke isUndefinedColumn (satu sumber predikat).
func isSkippedColumnMissing(err error) bool {
	return isUndefinedColumn(err)
}
