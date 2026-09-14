// Write-path: publish snapshot dalam satu transaksi (Save) + sinkronisasi tabel.

package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
)

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

	// 8. Auto-lock: semua game sudah "beres" (skor terisi ATAU sengaja tidak
	// dimainkan — seluruh pemain di-skip) ATAU tanggal lewat → lock otomatis.
	// Version tetap nextVersion (SATU bump per save) — sebelumnya di-increment
	// lagi (double bump n+1→n+2) bikin FE cache (n) kena 40001 di mutasi
	// berikutnya padahal lock yang menolak (audit RC2).
	// currentStatus == "" berarti sesi BARU (row belum ada / Scan gagal) — tetap
	// ikut auto-lock, kalau tidak sesi baru bertanggal lampau tidak pernah lock.
	if (currentStatus == "" || currentStatus == "draft") && status == "draft" {
		allDecided := len(snap.Schedule) > 0 && countDecidedGames(snap) == len(snap.Schedule)
		pastDate := false
		// Compare against WIB date (Asia/Jakarta) — venue selalu WIB.
		// DB current_date pakai UTC (container UTC) → sesi hari-H ke-lock prematur jam 07:00 WIB.
		var today string
		if err := tx.QueryRow(ctx, `SELECT (now() AT TIME ZONE 'Asia/Jakarta')::date::text`).Scan(&today); err == nil {
			pastDate = snap.Session.Date < today
		}
		if allDecided || pastDate {
			// Gunakan sessionID (bukan rowID) — untuk sesi baru, rowID="", sessionID berisi UUID
			// dari INSERT RETURNING. Untuk sesi lama, sessionID = rowID (keduanya sama).
			if _, err := tx.Exec(ctx, `
				UPDATE sessions SET status = 'locked', version = $2, updated_at = now()
				WHERE id = $1::uuid`, sessionID, nextVersion); err != nil {
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
		pid, ok, err := resolveTournamentPlayer(ctx, tx, s.schema, p.Name)
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
	// Snapshot skipped_player_refs SEBELUM delete. Snapshot publishable dari
	// klien (compat path) tidak membawa skip per-game, jadi tanpa ini DELETE +
	// re-insert akan menimpanya jadi '{}' (data loss senyap — audit 2026-09-12).
	// Kolom boleh belum ada (migration 000014 belum apply) → fallback ke INSERT lama.
	hasSkippedCol := true
	existingSkipped := map[string][]string{}
	srows, serr := tx.Query(ctx, `
		SELECT slot_index, court_index, COALESCE(skipped_player_refs, '{}')
		FROM scheduled_games WHERE session_id = $1::uuid`, sessionID)
	if serr != nil {
		if isSkippedColumnMissing(serr) {
			hasSkippedCol = false
		} else {
			return serr
		}
	} else {
		for srows.Next() {
			var slot, court int
			var refs []string
			if err := srows.Scan(&slot, &court, &refs); err != nil {
				srows.Close()
				return err
			}
			existingSkipped[domain.GameKey(slot, court)] = refs
		}
		if err := srows.Err(); err != nil {
			srows.Close()
			return err
		}
		srows.Close()
	}

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
		// Preserve skip per-game: pakai nilai dari snapshot bila dikirim
		// (non-nil), selain itu pertahankan nilai server sebelum delete.
		cols := `(session_id, legacy_order, slot_index, court_index, status, source, is_played, played_order`
		vals := `VALUES ($1::uuid, $2, $3, $4, $5, 'compat_publish', $6, $7`
		args := []any{sessionID, i, g.Slot, g.Court, status, isPlayed, nilableInt(playedOrder(i, isPlayed))}
		if hasSkippedCol {
			skipped := existingSkipped[key]
			if snap.SkippedPlayers != nil {
				skipped = snap.SkippedPlayers[key]
			}
			// Filter sadar-partisipan: hanya pertahankan ref yang benar-benar
			// bermain di game ini. Kalau schedule di-regenerate, skip lama tidak
			// boleh menempel ke pemain baru (temuan review 2026-09-12).
			parts := map[string]struct{}{}
			for _, r := range []string{g.TeamA[0], g.TeamA[1], g.TeamB[0], g.TeamB[1]} {
				parts[playerRef(r)] = struct{}{}
			}
			clean := make([]string, 0, len(skipped))
			seenRef := map[string]struct{}{}
			for _, r := range skipped {
				rr := playerRef(r)
				if _, ok := parts[rr]; !ok {
					continue
				}
				if _, dup := seenRef[rr]; dup {
					continue
				}
				seenRef[rr] = struct{}{}
				clean = append(clean, rr)
			}
			cols += `, skipped_player_refs`
			vals += `, $8::text[]`
			args = append(args, clean)
		}
		cols += `)`
		vals += `)`
		var internalID string
		if err := tx.QueryRow(ctx, `
			INSERT INTO scheduled_games `+cols+` `+vals+`
			RETURNING internal_id::text`, args...).Scan(&internalID); err != nil {
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
