package store

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"majadu-api/internal/domain"
)

// ── Player achievements (000016) ──────────────────────────────────────────
// Slice A: achievement Kelas A yang bisa di-backfill dari tabel yang masih
// ada (sesi, turnamen, snapshot season). Kelas B (per-match musim berjalan)
// ditangani di hook terpisah supaya tidak tercampur.

type achievementRow struct {
	PlayerID string
	Key      string
	Kind     string
	SeasonID *string
	EarnedAt string
	Value    *int64
	Meta     map[string]string
}

// AchievementView — kontrak JSON untuk frontend.
type AchievementView struct {
	Key      string            `json:"key"`
	Kind     string            `json:"kind"`
	Title    string            `json:"title"`
	Detail   string            `json:"detail"`
	Value    *int64            `json:"value,omitempty"`
	SeasonID string            `json:"seasonId,omitempty"`
	Season   string            `json:"season,omitempty"`
	EarnedAt string            `json:"earnedAt"`
	Meta     map[string]string `json:"meta,omitempty"`
}

// BackfillResult — ringkasan hasil backfill.
type BackfillResult struct {
	Unlocked int `json:"unlocked"`
	Records  int `json:"records"`
}

// PlayerAchievements — daftar achievement pemain, terbaru dulu.
func (s *SessionStore) PlayerAchievements(ctx context.Context, playerID string) ([]AchievementView, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT pa.achievement_key, pa.kind, pa.value, pa.earned_at::text,
		       COALESCE(pa.season_id::text, ''), COALESCE(rs.name, ''),
		       COALESCE(pa.meta::text, '{}')
		FROM `+s.schema+`.player_achievements pa
		LEFT JOIN `+s.schema+`.rating_seasons rs ON rs.id = pa.season_id
		WHERE pa.player_id = $1::uuid
		ORDER BY pa.earned_at DESC, pa.achievement_key ASC`, playerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []AchievementView{}
	for rows.Next() {
		var (
			v       AchievementView
			value   *int64
			metaRaw string
		)
		if err := rows.Scan(&v.Key, &v.Kind, &value, &v.EarnedAt, &v.SeasonID, &v.Season, &metaRaw); err != nil {
			return nil, err
		}
		v.Value = value
		v.Meta = map[string]string{}
		_ = json.Unmarshal([]byte(metaRaw), &v.Meta)
		v.Title, v.Detail = domain.DescribeAchievement(v.Kind, v.Key, value, v.Meta)
		out = append(out, v)
	}
	return out, rows.Err()
}

// insertAchievements — batch insert. record=false → ON CONFLICT DO NOTHING
// (unlock permanen); record=true → update bila value lebih besar (earned_at
// tetap tanggal pertama).
func (s *SessionStore) insertAchievements(ctx context.Context, rows []achievementRow, record bool) (int, error) {
	if len(rows) == 0 {
		return 0, nil
	}
	const chunk = 300
	total := 0
	for i := 0; i < len(rows); i += chunk {
		end := i + chunk
		if end > len(rows) {
			end = len(rows)
		}
		var sb strings.Builder
		args := make([]any, 0, (end-i)*7)
		sb.WriteString(`INSERT INTO ` + s.schema + `.player_achievements
			(player_id, achievement_key, kind, season_id, earned_at, value, meta) VALUES `)
		for j, r := range rows[i:end] {
			if j > 0 {
				sb.WriteString(", ")
			}
			b := len(args)
			sb.WriteString(fmt.Sprintf("($%d::uuid,$%d,$%d,$%d::uuid,$%d::date,$%d,$%d::jsonb)",
				b+1, b+2, b+3, b+4, b+5, b+6, b+7))
			meta, _ := json.Marshal(r.Meta)
			var season any
			if r.SeasonID != nil {
				season = *r.SeasonID
			}
			var value any
			if r.Value != nil {
				value = *r.Value
			}
			args = append(args, r.PlayerID, r.Key, r.Kind, season, r.EarnedAt, value, string(meta))
		}
		if record {
			sb.WriteString(` ON CONFLICT (player_id, achievement_key) DO UPDATE
				SET value = EXCLUDED.value, meta = EXCLUDED.meta, updated_at = now()
				WHERE player_achievements.value IS NULL OR EXCLUDED.value > player_achievements.value`)
		} else {
			sb.WriteString(` ON CONFLICT (player_id, achievement_key) DO NOTHING`)
		}
		tag, err := s.pool.Exec(ctx, sb.String(), args...)
		if err != nil {
			return total, err
		}
		total += int(tag.RowsAffected())
	}
	return total, nil
}

// ── Backfill ──────────────────────────────────────────────────────────────

type seasonInfo struct {
	ID, Name, Start, End string
}

type sessionInfo struct {
	ID   string
	Date string
}

type seasonEntry struct {
	seasonID, endDate string
	games, wins       int64
	peak, rd          float64
}

// BackfillAchievements — isi achievement Kelas A dari data historis.
// Idempoten: boleh dipanggil berulang.
func (s *SessionStore) BackfillAchievements(ctx context.Context) (BackfillResult, error) {
	cfg, err := s.LoadRatingConfig(ctx, false)
	if err != nil {
		return BackfillResult{}, err
	}

	seasons, seasonByID, openSeasonID, err := s.loadSeasons(ctx)
	if err != nil {
		return BackfillResult{}, err
	}
	_ = seasons

	sessions, sessionIdx, err := s.loadSessions(ctx)
	if err != nil {
		return BackfillResult{}, err
	}

	snaps, err := s.loadSeasonSnapshots(ctx)
	if err != nil {
		return BackfillResult{}, err
	}
	current, err := s.loadCurrentRatings(ctx)
	if err != nil {
		return BackfillResult{}, err
	}
	playerTiers, err := s.loadPlayerTiers(ctx)
	if err != nil {
		return BackfillResult{}, err
	}

	// orderedPlayerSeasons: per pemain, urut kronologis (snapshot season lama
	// lalu season berjalan).
	ordered := map[string][]seasonEntry{}
	for _, sn := range snaps {
		ordered[sn.playerID] = append(ordered[sn.playerID], seasonEntry{
			seasonID: sn.seasonID, endDate: sn.endDate,
			games: sn.games, wins: sn.wins, peak: sn.peak, rd: sn.rd,
		})
	}
	today := todayDate()
	for pid, c := range current {
		ordered[pid] = append(ordered[pid], seasonEntry{
			seasonID: openSeasonID, endDate: today,
			games: c.games, wins: c.wins, peak: c.peak, rd: c.rd,
		})
	}

	var unlocks, records []achievementRow
	seen := map[string]bool{}
	addUnlock := func(r achievementRow) {
		k := r.PlayerID + "\x00" + r.Key
		if seen[k] {
			return
		}
		seen[k] = true
		unlocks = append(unlocks, r)
	}
	recIdx := map[string]int{}
	addRecord := func(r achievementRow) {
		k := r.PlayerID + "\x00" + r.Key
		if i, ok := recIdx[k]; ok {
			if r.Value != nil && (records[i].Value == nil || *r.Value > *records[i].Value) {
				records[i] = r
			}
			return
		}
		recIdx[k] = len(records)
		records = append(records, r)
	}

	// ── Keluarga 5 & Tier: milestone rating + breakthrough, per season ────
	for pid, entries := range ordered {
		sticky := playerTiers[pid]
		stickyRank := domain.RankTier(sticky)
		var (
			cumGames, cumWins int64
			reachedRating     = map[int64]bool{}
			reachedTier       = map[int]bool{}
			established       bool
		)
		for _, e := range entries {
			cumGames += e.games
			cumWins += e.wins
			sid := e.seasonID
			var seasonPtr *string
			if sid != "" {
				seasonPtr = &sid
			}
			// volume: game & menang
			for _, th := range domain.GamesThresholds {
				if cumGames >= th {
					addUnlock(achievementRow{PlayerID: pid, Key: domain.GamesKey(th), Kind: string(domain.AchVolume),
						SeasonID: seasonPtr, EarnedAt: e.endDate, Meta: map[string]string{"count": fmt.Sprint(th)}})
				}
			}
			for _, th := range domain.WinsThresholds {
				if cumWins >= th {
					addUnlock(achievementRow{PlayerID: pid, Key: domain.WinsKey(th), Kind: string(domain.AchVolume),
						SeasonID: seasonPtr, EarnedAt: e.endDate, Meta: map[string]string{"count": fmt.Sprint(th)}})
				}
			}
			// rating milestone (basis peak)
			for _, th := range domain.RatingThresholds {
				if e.peak >= float64(th) && !reachedRating[th] {
					reachedRating[th] = true
					addUnlock(achievementRow{PlayerID: pid, Key: domain.RatingKey(th), Kind: string(domain.AchRating),
						SeasonID: seasonPtr, EarnedAt: e.endDate, Meta: map[string]string{"rating": fmt.Sprint(th)}})
				}
			}
			// established (RD < 50)
			if !established && e.rd > 0 && e.rd < domain.EstablishedRD {
				established = true
				addUnlock(achievementRow{PlayerID: pid, Key: domain.EstablishedKey, Kind: string(domain.AchRank),
					SeasonID: seasonPtr, EarnedAt: e.endDate})
			}
			// breakthrough tier: setiap ambang di atas sticky
			if stickyRank >= 0 {
				peakRank := domain.RankTier(cfg.TierForRating(e.peak))
				for t := stickyRank + 1; t < len(domain.TierOrder); t++ {
					if peakRank >= t && !reachedTier[t] {
						reachedTier[t] = true
						tier := domain.TierOrder[t]
						addUnlock(achievementRow{PlayerID: pid, Key: domain.TierKey(tier), Kind: string(domain.AchTier),
							SeasonID: seasonPtr, EarnedAt: e.endDate, Meta: map[string]string{"tier": tier}})
					}
				}
			}
			// season member
			if e.games > 0 && sid != "" {
				addUnlock(achievementRow{PlayerID: pid, Key: domain.SeasonMemberKey(sid), Kind: string(domain.AchSeason),
					SeasonID: seasonPtr, EarnedAt: e.endDate, Meta: map[string]string{"season": seasonByID[sid].Name}})
			}
		}
		// win rate karier
		if len(entries) > 0 && cumGames >= domain.WinRateMinGames && cumWins*100 >= domain.WinRatePct*cumGames {
			last := entries[len(entries)-1]
			var seasonPtr *string
			if last.seasonID != "" {
				seasonPtr = &last.seasonID
			}
			addUnlock(achievementRow{PlayerID: pid, Key: domain.WinRateKey, Kind: string(domain.AchVolume),
				SeasonID: seasonPtr, EarnedAt: last.endDate,
				Meta: map[string]string{"pct": fmt.Sprint(domain.WinRatePct), "min": fmt.Sprint(domain.WinRateMinGames)}})
		}
	}

	// ── Keluarga 1: kehadiran (first, count, streak, full attendance) ──────
	if err := s.backfillAttendance(ctx, sessions, sessionIdx, seasons, addUnlock, addRecord); err != nil {
		return BackfillResult{}, err
	}

	// ── Keluarga 4: turnamen (partisipasi, count, juara, podium) ───────────
	if err := s.backfillTournaments(ctx, addUnlock); err != nil {
		return BackfillResult{}, err
	}

	// ── Keluarga 6: sosial (partner & lawan berbeda) ───────────────────────
	if err := s.backfillSocial(ctx, addUnlock); err != nil {
		return BackfillResult{}, err
	}

	// ── Rekor: margin, partner terbaik, streak sesi ─────────────────────────
	if err := s.backfillRecords(ctx, addRecord); err != nil {
		return BackfillResult{}, err
	}

	// ── Keluarga 5 lanjutan: juara/podium season (rank dari snapshot) ──────
	if err := s.backfillSeasonRank(ctx, addUnlock); err != nil {
		return BackfillResult{}, err
	}

	unlocked, err := s.insertAchievements(ctx, unlocks, false)
	if err != nil {
		return BackfillResult{}, err
	}
	recs, err := s.insertAchievements(ctx, records, true)
	if err != nil {
		return BackfillResult{}, err
	}
	return BackfillResult{Unlocked: unlocked, Records: recs}, nil
}

// ── Loader helpers ────────────────────────────────────────────────────────

func (s *SessionStore) loadSeasons(ctx context.Context) ([]seasonInfo, map[string]seasonInfo, string, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT id::text, name, start_date::text, COALESCE(end_date::text, '')
		FROM `+s.schema+`.rating_seasons ORDER BY start_date ASC`)
	if err != nil {
		return nil, nil, "", err
	}
	defer rows.Close()
	out := []seasonInfo{}
	byID := map[string]seasonInfo{}
	open := ""
	for rows.Next() {
		var si seasonInfo
		if err := rows.Scan(&si.ID, &si.Name, &si.Start, &si.End); err != nil {
			return nil, nil, "", err
		}
		out = append(out, si)
		byID[si.ID] = si
		if si.End == "" {
			open = si.ID
		}
	}
	return out, byID, open, rows.Err()
}

func (s *SessionStore) loadSessions(ctx context.Context) ([]sessionInfo, map[string]int, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT id::text, session_date::text
		FROM `+s.schema+`.sessions WHERE status <> 'draft'
		ORDER BY session_date ASC, created_at ASC`)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	out := []sessionInfo{}
	idx := map[string]int{}
	for rows.Next() {
		var si sessionInfo
		if err := rows.Scan(&si.ID, &si.Date); err != nil {
			return nil, nil, err
		}
		idx[si.ID] = len(out)
		out = append(out, si)
	}
	return out, idx, rows.Err()
}

type snapRow struct {
	playerID, seasonID, endDate string
	rating, rd, peak            float64
	games, wins                 int64
}

func (s *SessionStore) loadSeasonSnapshots(ctx context.Context) ([]snapRow, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT sp.player_id::text, sp.season_id::text, sp.rating, sp.rd, sp.peak,
		       sp.games, sp.wins, r.end_date::text
		FROM `+s.schema+`.season_player_snapshots sp
		JOIN `+s.schema+`.rating_seasons r ON r.id = sp.season_id
		ORDER BY r.start_date ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []snapRow{}
	for rows.Next() {
		var r snapRow
		if err := rows.Scan(&r.playerID, &r.seasonID, &r.rating, &r.rd, &r.peak, &r.games, &r.wins, &r.endDate); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

type currentRating struct {
	sticky              string
	rating, rd, peak    float64
	games, wins, losses int64
}

func (s *SessionStore) loadCurrentRatings(ctx context.Context) (map[string]currentRating, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT rp.player_id::text, COALESCE(p.tier, ''), rp.rating, rp.rd, rp.peak_rating,
		       rp.games_played, rp.wins, rp.losses
		FROM `+s.schema+`.rating_players rp
		JOIN `+s.schema+`.players p ON p.id = rp.player_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]currentRating{}
	for rows.Next() {
		var (
			pid string
			c   currentRating
		)
		if err := rows.Scan(&pid, &c.sticky, &c.rating, &c.rd, &c.peak, &c.games, &c.wins, &c.losses); err != nil {
			return nil, err
		}
		out[pid] = c
	}
	return out, rows.Err()
}

// ── Keluarga 1: kehadiran ─────────────────────────────────────────────────

func (s *SessionStore) backfillAttendance(
	ctx context.Context,
	sessions []sessionInfo,
	sessionIdx map[string]int,
	seasons []seasonInfo,
	add func(achievementRow),
	addRecord func(achievementRow),
) error {
	rows, err := s.pool.Query(ctx, `
		SELECT sp.player_id::text, s.id::text, s.session_date::text, sp.is_absent
		FROM `+s.schema+`.session_players sp
		JOIN `+s.schema+`.sessions s ON s.id = sp.session_id
		WHERE sp.player_id IS NOT NULL AND s.status <> 'draft'`)
	if err != nil {
		return err
	}
	defer rows.Close()

	type att struct {
		sessionID string
		date      string
		absent    bool
	}
	byPlayer := map[string][]att{}
	for rows.Next() {
		var (
			pid string
			a   att
		)
		if err := rows.Scan(&pid, &a.sessionID, &a.date, &a.absent); err != nil {
			return err
		}
		byPlayer[pid] = append(byPlayer[pid], a)
	}
	if err := rows.Err(); err != nil {
		return err
	}

	// Sesi per season (untuk hadir penuh).
	seasonSessions := map[string][]sessionInfo{}
	for _, sess := range sessions {
		if sid, ok := seasonForDate(seasons, sess.Date); ok {
			seasonSessions[sid] = append(seasonSessions[sid], sess)
		}
	}

	for pid, list := range byPlayer {
		attended := map[string]bool{}
		seenList := map[string]bool{}
		ordered := make([]att, 0, len(list))
		for _, a := range list {
			if seenList[a.sessionID] {
				continue
			}
			seenList[a.sessionID] = true
			ordered = append(ordered, a)
			if !a.absent {
				attended[a.sessionID] = true
			}
		}
		sort.Slice(ordered, func(i, j int) bool { return sessionIdx[ordered[i].sessionID] < sessionIdx[ordered[j].sessionID] })

		// first + count
		var attendedOrdered []att
		for _, a := range ordered {
			if a.absent {
				continue
			}
			attendedOrdered = append(attendedOrdered, a)
		}
		if len(attendedOrdered) > 0 {
			add(achievementRow{PlayerID: pid, Key: domain.FirstSessionKey, Kind: string(domain.AchAttendance),
				EarnedAt: attendedOrdered[0].date})
		}
		for i, a := range attendedOrdered {
			n := int64(i + 1)
			for _, th := range domain.SessionCountThresholds {
				if n == th {
					add(achievementRow{PlayerID: pid, Key: domain.SessionCountKey(th), Kind: string(domain.AchAttendance),
						EarnedAt: a.date, Meta: map[string]string{"count": fmt.Sprint(th)}})
				}
			}
		}

		// streak atas sesi global (bolong = putus)
		run, maxRun := 0, 0
		var maxRunDate string
		hit := map[int64]bool{}
		for _, sess := range sessions {
			if attended[sess.ID] {
				run++
			} else {
				run = 0
			}
			if run > maxRun {
				maxRun = run
				maxRunDate = sess.Date
			}
			for _, th := range domain.StreakThresholds {
				if int64(run) >= th && !hit[th] {
					hit[th] = true
					add(achievementRow{PlayerID: pid, Key: domain.StreakKey(th), Kind: string(domain.AchAttendance),
						EarnedAt: sess.Date, Meta: map[string]string{"count": fmt.Sprint(th)}})
				}
			}
		}
		if maxRun > 0 {
			addRecord(achievementRow{PlayerID: pid, Key: domain.RecordStreak, Kind: string(domain.AchAttendance),
				EarnedAt: maxRunDate, Value: i64(maxRun), Meta: map[string]string{"count": fmt.Sprint(maxRun)}})
		}

		// hadir penuh per season
		for sid, sSessions := range seasonSessions {
			if len(sSessions) == 0 {
				continue
			}
			all := true
			anyAttended := false
			lastDate := sSessions[len(sSessions)-1].Date
			for _, sess := range sSessions {
				if !attended[sess.ID] {
					all = false
					break
				}
				anyAttended = true
			}
			if all && anyAttended {
				seasonID := sid
				name := ""
				for _, si := range seasons {
					if si.ID == sid {
						name = si.Name
					}
				}
				add(achievementRow{PlayerID: pid, Key: "full_attendance:" + sid, Kind: string(domain.AchAttendance),
					SeasonID: &seasonID, EarnedAt: lastDate, Meta: map[string]string{"season": name}})
			}
		}
	}
	return nil
}

// ── Keluarga 4: turnamen ──────────────────────────────────────────────────

func (s *SessionStore) backfillTournaments(ctx context.Context, add func(achievementRow)) error {
	// partisipasi
	rows, err := s.pool.Query(ctx, `
		SELECT tpp.player_id::text, t.id::text, t.name, t.event_date::text
		FROM `+s.schema+`.tournament_pair_players tpp
		JOIN `+s.schema+`.tournament_pairs tp ON tp.id = tpp.pair_id
		JOIN `+s.schema+`.tournaments t ON t.id = tp.tournament_id
		WHERE tpp.player_id IS NOT NULL
		UNION ALL
		SELECT ttp.player_id::text, t.id::text, t.name, t.event_date::text
		FROM `+s.schema+`.tournament_team_players ttp
		JOIN `+s.schema+`.tournament_teams tt ON tt.id = ttp.team_id
		JOIN `+s.schema+`.tournaments t ON t.id = tt.tournament_id
		WHERE ttp.player_id IS NOT NULL`)
	if err != nil {
		return err
	}
	type part struct {
		tid, name, date string
	}
	byPlayer := map[string][]part{}
	for rows.Next() {
		var (
			pid string
			p   part
		)
		if err := rows.Scan(&pid, &p.tid, &p.name, &p.date); err != nil {
			rows.Close()
			return err
		}
		byPlayer[pid] = append(byPlayer[pid], p)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for pid, list := range byPlayer {
		uniq := map[string]part{}
		for _, p := range list {
			uniq[p.tid] = p
		}
		ordered := make([]part, 0, len(uniq))
		for _, p := range uniq {
			ordered = append(ordered, p)
		}
		sort.Slice(ordered, func(i, j int) bool { return ordered[i].date < ordered[j].date })
		for _, p := range ordered {
			add(achievementRow{PlayerID: pid, Key: domain.TournamentKey(p.tid), Kind: string(domain.AchTournament),
				EarnedAt: p.date, Meta: map[string]string{"name": p.name}})
		}
		for i, p := range ordered {
			n := int64(i + 1)
			for _, th := range domain.TournamentThresholds {
				if n == th {
					add(achievementRow{PlayerID: pid, Key: domain.TournamentCountKey(th), Kind: string(domain.AchTournament),
						EarnedAt: p.date, Meta: map[string]string{"count": fmt.Sprint(th)}})
				}
			}
		}
	}

	// juara/podium classic
	cRows, err := s.pool.Query(ctx, `
		SELECT tm.tournament_id::text, t.name, t.event_date::text, tm.phase,
		       tm.pair_a_id::text, tm.pair_b_id::text, tm.score_a, tm.score_b
		FROM `+s.schema+`.tournament_matches tm
		JOIN `+s.schema+`.tournaments t ON t.id = tm.tournament_id
		WHERE tm.phase IN ('final','3rd') AND tm.score_a IS NOT NULL AND tm.score_b IS NOT NULL
		  AND tm.pair_a_id IS NOT NULL AND tm.pair_b_id IS NOT NULL`)
	if err != nil {
		return err
	}
	type finalInfo struct {
		tid, name, date string
		winPair         string
		kind            string // champion | podium
	}
	finals := []finalInfo{}
	for cRows.Next() {
		var (
			tid, name, date, phase, pa, pb string
			sa, sb                         int
		)
		if err := cRows.Scan(&tid, &name, &date, &phase, &pa, &pb, &sa, &sb); err != nil {
			cRows.Close()
			return err
		}
		winner, loser := pa, pb
		if sb > sa {
			winner, loser = pb, pa
		}
		if phase == "final" {
			finals = append(finals,
				finalInfo{tid: tid, name: name, date: date, winPair: winner, kind: "champion"},
				finalInfo{tid: tid, name: name, date: date, winPair: loser, kind: "podium"})
		} else {
			finals = append(finals, finalInfo{tid: tid, name: name, date: date, winPair: winner, kind: "podium"})
		}
	}
	cRows.Close()
	if err := cRows.Err(); err != nil {
		return err
	}
	pairPlayers, err := s.loadPairPlayers(ctx)
	if err != nil {
		return err
	}
	for _, f := range finals {
		for _, pid := range pairPlayers[f.winPair] {
			if f.kind == "champion" {
				add(achievementRow{PlayerID: pid, Key: domain.ChampionKey(f.tid), Kind: string(domain.AchTournament),
					EarnedAt: f.date, Meta: map[string]string{"name": f.name}})
			} else {
				add(achievementRow{PlayerID: pid, Key: domain.PodiumKey(f.tid), Kind: string(domain.AchTournament),
					EarnedAt: f.date, Meta: map[string]string{"name": f.name}})
			}
		}
	}

	// juara/podium team
	tRows, err := s.pool.Query(ctx, `
		SELECT tm.tournament_id::text, t.name, t.event_date::text,
		       tm.team_a_id::text, tm.team_b_id::text,
		       COALESCE(sum(CASE WHEN g.score_a > g.score_b THEN 1 ELSE 0 END), 0)::int,
		       COALESCE(sum(CASE WHEN g.score_b > g.score_a THEN 1 ELSE 0 END), 0)::int
		FROM `+s.schema+`.tournament_team_matches tm
		JOIN `+s.schema+`.tournaments t ON t.id = tm.tournament_id
		LEFT JOIN `+s.schema+`.tournament_team_match_games g ON g.team_match_id = tm.id
		WHERE tm.phase = 'final'
		GROUP BY 1,2,3,4,5`)
	if err != nil {
		return err
	}
	teamPlayers, err := s.loadTeamPlayers(ctx)
	if err != nil {
		tRows.Close()
		return err
	}
	for tRows.Next() {
		var (
			tid, name, date, ta, tb string
			wa, wb                  int
		)
		if err := tRows.Scan(&tid, &name, &date, &ta, &tb, &wa, &wb); err != nil {
			tRows.Close()
			return err
		}
		if wb > wa {
			ta, tb = tb, ta
		}
		for _, pid := range teamPlayers[ta] {
			add(achievementRow{PlayerID: pid, Key: domain.ChampionKey(tid), Kind: string(domain.AchTournament),
				EarnedAt: date, Meta: map[string]string{"name": name}})
		}
		for _, pid := range teamPlayers[tb] {
			add(achievementRow{PlayerID: pid, Key: domain.PodiumKey(tid), Kind: string(domain.AchTournament),
				EarnedAt: date, Meta: map[string]string{"name": name}})
		}
	}
	tRows.Close()
	return tRows.Err()
}

func (s *SessionStore) loadPairPlayers(ctx context.Context) (map[string][]string, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT pair_id::text, player_id::text FROM `+s.schema+`.tournament_pair_players
		WHERE player_id IS NOT NULL`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string][]string{}
	for rows.Next() {
		var pair, pid string
		if err := rows.Scan(&pair, &pid); err != nil {
			return nil, err
		}
		out[pair] = append(out[pair], pid)
	}
	return out, rows.Err()
}

func (s *SessionStore) loadTeamPlayers(ctx context.Context) (map[string][]string, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT team_id::text, player_id::text FROM `+s.schema+`.tournament_team_players
		WHERE player_id IS NOT NULL`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string][]string{}
	for rows.Next() {
		var team, pid string
		if err := rows.Scan(&team, &pid); err != nil {
			return nil, err
		}
		out[team] = append(out[team], pid)
	}
	return out, rows.Err()
}

// ── Keluarga 6: sosial ────────────────────────────────────────────────────

func (s *SessionStore) backfillSocial(ctx context.Context, add func(achievementRow)) error {
	today := todayDate()
	for _, spec := range []struct {
		table      string
		joinCond   string
		thresholds []int64
		keyFn      func(int64) string
	}{{
		table: "a", joinCond: "tl.team = sgp.team AND tl.session_player_internal_id <> sp.internal_id",
		thresholds: domain.PartnerThresholds, keyFn: domain.PartnersKey,
	}, {
		table: "b", joinCond: "tl.team <> sgp.team",
		thresholds: domain.OpponentThresholds, keyFn: domain.OpponentsKey,
	}} {
		rows, err := s.pool.Query(ctx, `
			SELECT sp.player_id::text, count(DISTINCT tsp.player_id)::int
			FROM `+s.schema+`.session_players sp
			JOIN `+s.schema+`.scheduled_game_players sgp ON sgp.session_player_internal_id = sp.internal_id
			JOIN `+s.schema+`.scheduled_games sg ON sg.internal_id = sgp.scheduled_game_internal_id AND sg.session_id = sp.session_id
			JOIN `+s.schema+`.scheduled_game_players tl ON tl.scheduled_game_internal_id = sg.internal_id AND `+spec.joinCond+`
			JOIN `+s.schema+`.session_players tsp ON tsp.internal_id = tl.session_player_internal_id
			WHERE sp.player_id IS NOT NULL AND tsp.player_id IS NOT NULL AND sp.is_absent = false
			  AND sg.score_a IS NOT NULL AND sg.score_b IS NOT NULL
			GROUP BY 1`)
		if err != nil {
			return err
		}
		for rows.Next() {
			var pid string
			var n int64
			if err := rows.Scan(&pid, &n); err != nil {
				rows.Close()
				return err
			}
			kind := string(domain.AchSocial)
			if spec.table == "b" {
				kind = string(domain.AchOpponent)
			}
			for _, th := range spec.thresholds {
				if n >= th {
					add(achievementRow{PlayerID: pid, Key: spec.keyFn(th), Kind: kind,
						EarnedAt: today, Meta: map[string]string{"count": fmt.Sprint(th)}})
				}
			}
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
	}
	return nil
}

// ── Rekor ─────────────────────────────────────────────────────────────────

func (s *SessionStore) backfillRecords(ctx context.Context, addRecord func(achievementRow)) error {
	// margin + skor sempurna
	rows, err := s.pool.Query(ctx, `
		SELECT sp.player_id::text,
		       max(CASE WHEN ((sgp.team = 'A' AND sg.score_a > sg.score_b) OR (sgp.team = 'B' AND sg.score_b > sg.score_a))
		                THEN abs(sg.score_a - sg.score_b) ELSE 0 END)::int,
		       COALESCE(bool_or((sgp.team = 'A' AND sg.score_a = 30 AND sg.score_b = 0)
		                     OR (sgp.team = 'B' AND sg.score_b = 30 AND sg.score_a = 0)), false)
		FROM `+s.schema+`.session_players sp
		JOIN `+s.schema+`.scheduled_game_players sgp ON sgp.session_player_internal_id = sp.internal_id
		JOIN `+s.schema+`.scheduled_games sg ON sg.internal_id = sgp.scheduled_game_internal_id AND sg.session_id = sp.session_id
		WHERE sp.player_id IS NOT NULL AND sp.is_absent = false
		  AND sg.score_a IS NOT NULL AND sg.score_b IS NOT NULL
		GROUP BY 1`)
	if err != nil {
		return err
	}
	for rows.Next() {
		var (
			pid     string
			margin  int64
			perfect bool
		)
		if err := rows.Scan(&pid, &margin, &perfect); err != nil {
			rows.Close()
			return err
		}
		if margin > 0 {
			addRecord(achievementRow{PlayerID: pid, Key: domain.RecordMargin, Kind: string(domain.AchVolume),
				EarnedAt: todayDate(), Value: i64(int(margin)), Meta: map[string]string{"margin": fmt.Sprint(margin)}})
		}
		if perfect {
			addRecord(achievementRow{PlayerID: pid, Key: domain.PerfectKey, Kind: string(domain.AchVolume),
				EarnedAt: todayDate(), Value: i64(1)})
		}
		if margin >= domain.MarginThreshold {
			addRecord(achievementRow{PlayerID: pid, Key: domain.MarginKey, Kind: string(domain.AchVolume),
				EarnedAt: todayDate(), Value: i64(int(margin)), Meta: map[string]string{"margin": fmt.Sprint(margin)}})
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	// partner terbaik
	pRows, err := s.pool.Query(ctx, `
		SELECT sp.player_id::text, partner.canonical_name, count(*)::int
		FROM `+s.schema+`.session_players sp
		JOIN `+s.schema+`.scheduled_game_players sgp ON sgp.session_player_internal_id = sp.internal_id
		JOIN `+s.schema+`.scheduled_games sg ON sg.internal_id = sgp.scheduled_game_internal_id AND sg.session_id = sp.session_id
		JOIN `+s.schema+`.scheduled_game_players tl ON tl.scheduled_game_internal_id = sg.internal_id
			AND tl.team = sgp.team AND tl.session_player_internal_id <> sp.internal_id
		JOIN `+s.schema+`.session_players tsp ON tsp.internal_id = tl.session_player_internal_id
		JOIN `+s.schema+`.players partner ON partner.id = tsp.player_id
		WHERE sp.player_id IS NOT NULL AND tsp.player_id IS NOT NULL AND sp.is_absent = false
		  AND sg.score_a IS NOT NULL AND sg.score_b IS NOT NULL
		GROUP BY 1,2`)
	if err != nil {
		return err
	}
	best := map[string]struct {
		name  string
		count int64
	}{}
	for pRows.Next() {
		var (
			pid, partner string
			n            int64
		)
		if err := pRows.Scan(&pid, &partner, &n); err != nil {
			pRows.Close()
			return err
		}
		if cur, ok := best[pid]; !ok || n > cur.count {
			best[pid] = struct {
				name  string
				count int64
			}{name: partner, count: n}
		}
	}
	pRows.Close()
	if err := pRows.Err(); err != nil {
		return err
	}
	for pid, b := range best {
		addRecord(achievementRow{PlayerID: pid, Key: domain.RecordTopPartner, Kind: string(domain.AchSocial),
			EarnedAt: todayDate(), Value: i64(int(b.count)),
			Meta: map[string]string{"partner": b.name, "games": fmt.Sprint(b.count)}})
	}
	return nil
}

// ── Keluarga 5 lanjutan: juara/podium season ──────────────────────────────

func (s *SessionStore) backfillSeasonRank(ctx context.Context, add func(achievementRow)) error {
	rows, err := s.pool.Query(ctx, `
		SELECT sp.player_id::text, sp.season_id::text, r.name, r.end_date::text, sp.rating
		FROM `+s.schema+`.season_player_snapshots sp
		JOIN `+s.schema+`.rating_seasons r ON r.id = sp.season_id
		ORDER BY sp.season_id, sp.rating DESC, sp.player_name ASC`)
	if err != nil {
		return err
	}
	defer rows.Close()
	type sr struct {
		pid    string
		season string
		name   string
		end    string
	}
	bySeason := map[string][]sr{}
	meta := map[string]seasonInfo{}
	for rows.Next() {
		var (
			r        sr
			rating   float64
			seasonID string
		)
		if err := rows.Scan(&r.pid, &seasonID, &r.name, &r.end, &rating); err != nil {
			return err
		}
		bySeason[seasonID] = append(bySeason[seasonID], r)
		meta[seasonID] = seasonInfo{ID: seasonID, Name: r.name, End: r.end}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	for sid, list := range bySeason {
		si := meta[sid]
		seasonID := sid
		for i, r := range list {
			rank := i + 1
			if rank == 1 {
				add(achievementRow{PlayerID: r.pid, Key: domain.SeasonChampionKey(sid), Kind: string(domain.AchSeason),
					SeasonID: &seasonID, EarnedAt: si.End, Meta: map[string]string{"season": si.Name}})
			}
			if rank <= 3 {
				add(achievementRow{PlayerID: r.pid, Key: domain.SeasonPodiumKey(sid), Kind: string(domain.AchSeason),
					SeasonID: &seasonID, EarnedAt: si.End, Meta: map[string]string{"season": si.Name}})
			}
		}
	}
	return nil
}

// ── util ──────────────────────────────────────────────────────────────────

func seasonForDate(seasons []seasonInfo, date string) (string, bool) {
	for _, si := range seasons {
		if date >= si.Start && (si.End == "" || date <= si.End) {
			return si.ID, true
		}
	}
	return "", false
}

func todayDate() string {
	return time.Now().Format("2006-01-02")
}

// loadPlayerTiers — sticky tier semua pemain (players.tier), termasuk yang
// tidak punya baris rating_players musim berjalan.
func (s *SessionStore) loadPlayerTiers(ctx context.Context) (map[string]string, error) {
	rows, err := s.pool.Query(ctx, `SELECT id::text, COALESCE(tier, '') FROM `+s.schema+`.players`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var pid, tier string
		if err := rows.Scan(&pid, &tier); err != nil {
			return nil, err
		}
		out[pid] = tier
	}
	return out, rows.Err()
}

func i64(n int) *int64 {
	v := int64(n)
	return &v
}
