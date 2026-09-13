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
// Model medal bertingkat (konsep Ingress): satu medal = satu statistik dengan
// tangga 5 tingkat. Yang disimpan hanya nilai statistiknya; tingkat dihitung
// dari katalog domain saat dibaca.
//
// Dua kelompok tulis:
//   - medal  → upsert `value` (naik), earned_at tetap tanggal pertama.
//   - collectible → sekali dapat (ON CONFLICT DO NOTHING).

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
	Key        string            `json:"key"`
	Kind       string            `json:"kind"`
	Title      string            `json:"title"`
	Detail     string            `json:"detail"`
	Value      *int64            `json:"value,omitempty"`
	TierLevel  int               `json:"tierLevel,omitempty"`  // 1..5 untuk medal, 0 untuk collectible
	TierName   string            `json:"tierName,omitempty"`   // Bronze..Onyx
	NextTarget *int64            `json:"nextTarget,omitempty"` // ambang tingkat berikutnya
	SeasonID   string            `json:"seasonId,omitempty"`
	Season     string            `json:"season,omitempty"`
	EarnedAt   string            `json:"earnedAt"`
	Meta       map[string]string `json:"meta,omitempty"`
}

// BackfillResult — ringkasan hasil backfill.
type BackfillResult struct {
	Medals       int `json:"medals"`
	Collectibles int `json:"collectibles"`
}

// PlayerAchievements — daftar achievement pemain. Medal duluan (biar rak
// konsisten), lalu collectible, masing-masing terbaru dulu.
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
		if title, unit, _, def, ok := domain.TitleForMedal(v.Key); ok {
			level := int64(0)
			if value != nil {
				level = int64(domain.TierForValue(def, *value))
			}
			v.Title = title
			v.TierLevel = int(level)
			v.TierName = domain.TierName(int(level))
			if next, has := domain.NextTarget(def, int(level)); has {
				v.NextTarget = &next
			}
			if value != nil {
				v.Detail = fmt.Sprintf("%d %s", *value, unit)
			}
		} else {
			v.Title, v.Detail = domain.DescribeCollectible(v.Kind, v.Key, v.Meta)
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

// insertAchievements — batch insert. record=false → DO NOTHING (collectible);
// record=true → update bila value lebih besar (medal; earned_at tetap).
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

type checkpoint struct {
	value int64
	date  string
}

// BackfillAchievements — bangun ulang medal + collectible dari data historis.
// Idempoten.
func (s *SessionStore) BackfillAchievements(ctx context.Context) (BackfillResult, error) {
	cfg, err := s.LoadRatingConfig(ctx, false)
	if err != nil {
		return BackfillResult{}, err
	}
	seasons, seasonByID, openSeasonID, err := s.loadSeasons(ctx)
	if err != nil {
		return BackfillResult{}, err
	}
	sessions, sessionIdx, err := s.loadSessions(ctx)
	if err != nil {
		return BackfillResult{}, err
	}
	seasonOfSession := map[string]string{}
	seasonSessions := map[string][]sessionInfo{}
	for _, sess := range sessions {
		if sid, ok := seasonForDate(seasons, sess.Date); ok {
			seasonOfSession[sess.ID] = sid
			seasonSessions[sid] = append(seasonSessions[sid], sess)
		}
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

	today := todayDate()
	ordered := map[string][]seasonEntry{}
	for _, sn := range snaps {
		ordered[sn.playerID] = append(ordered[sn.playerID], seasonEntry{
			seasonID: sn.seasonID, endDate: sn.endDate,
			games: sn.games, wins: sn.wins, peak: sn.peak, rd: sn.rd,
		})
	}
	for pid, c := range current {
		ordered[pid] = append(ordered[pid], seasonEntry{
			seasonID: openSeasonID, endDate: today,
			games: c.games, wins: c.wins, peak: c.peak, rd: c.rd,
		})
	}

	var medals, collectibles []achievementRow
	seenCollectible := map[string]bool{}
	addCollectible := func(r achievementRow) {
		k := r.PlayerID + "\x00" + r.Key
		if seenCollectible[k] {
			return
		}
		seenCollectible[k] = true
		collectibles = append(collectibles, r)
	}
	addMedal := func(pid string, def domain.MedalDef, value int64, seasonID, earnedAt string, meta map[string]string) {
		if value < def.Thresholds[0] {
			return
		}
		var seasonPtr *string
		if seasonID != "" {
			seasonPtr = &seasonID
		}
		v := value
		medals = append(medals, achievementRow{
			PlayerID: pid, Key: domain.MedalKey(def.ID), Kind: string(def.Kind),
			SeasonID: seasonPtr, EarnedAt: earnedAt, Value: &v, Meta: meta,
		})
	}
	addSeasonMedal := func(pid, seasonID, seasonName string, def domain.MedalDef, value int64, earnedAt string) {
		if value < def.Thresholds[0] {
			return
		}
		v := value
		sid := seasonID
		medals = append(medals, achievementRow{
			PlayerID: pid, Key: domain.SeasonMedalKey(seasonID, def.ID), Kind: string(def.Kind),
			SeasonID: &sid, EarnedAt: earnedAt, Value: &v, Meta: map[string]string{"season": seasonName},
		})
	}

	// ── Medali career yang sifatnya kumulatif / max dari data season ──────
	for pid, entries := range ordered {
		if len(entries) == 0 {
			continue
		}
		sticky := playerTiers[pid]
		stickyRank := domain.RankTier(sticky)
		var (
			gamesCk, winsCk, ratingCk []checkpoint
			games, wins               int64
			peakMax                   float64
			rdMin                     float64
			reachedTier               = map[int]bool{}
		)
		for _, e := range entries {
			games += e.games
			wins += e.wins
			if e.peak > peakMax {
				peakMax = e.peak
			}
			if e.rd > 0 && (rdMin == 0 || e.rd < rdMin) {
				rdMin = e.rd
			}
			if e.games > 0 || e.wins > 0 || e.peak > 0 {
				gamesCk = append(gamesCk, checkpoint{value: games, date: e.endDate})
				winsCk = append(winsCk, checkpoint{value: wins, date: e.endDate})
				ratingCk = append(ratingCk, checkpoint{value: int64(peakMax), date: e.endDate})
			}
			if stickyRank >= 0 {
				peakRank := domain.RankTier(cfg.TierForRating(e.peak))
				for t := stickyRank + 1; t < len(domain.TierOrder); t++ {
					if peakRank >= t && !reachedTier[t] {
						reachedTier[t] = true
						tier := domain.TierOrder[t]
						var seasonPtr *string
						if e.seasonID != "" {
							seasonPtr = &e.seasonID
						}
						addCollectible(achievementRow{PlayerID: pid, Key: domain.TierKey(tier), Kind: string(domain.AchTier),
							SeasonID: seasonPtr, EarnedAt: e.endDate, Meta: map[string]string{"tier": tier}})
					}
				}
			}
			if e.games > 0 && e.seasonID != "" {
				sid := e.seasonID
				addCollectible(achievementRow{PlayerID: pid, Key: domain.SeasonMemberKey(sid), Kind: string(domain.AchSeason),
					SeasonID: &sid, EarnedAt: e.endDate, Meta: map[string]string{"season": seasonByID[sid].Name}})
			}
		}
		addMedal(pid, mustMedal("games"), games, lastSeasonID(entries), firstDateAt(gamesCk, mustMedal("games").Thresholds[0], today), nil)
		addMedal(pid, mustMedal("wins"), wins, lastSeasonID(entries), firstDateAt(winsCk, mustMedal("wins").Thresholds[0], today), nil)
		addMedal(pid, mustMedal("rating"), int64(peakMax), "", firstDateAt(ratingCk, mustMedal("rating").Thresholds[0], today), nil)
		if rdMin > 0 && rdMin < domain.EstablishedRD {
			addCollectible(achievementRow{PlayerID: pid, Key: domain.EstablishedKey, Kind: string(domain.AchRank), EarnedAt: today})
		}
		if games >= domain.EfficientMin && wins*100 >= int64(domain.EfficientPct)*games {
			addCollectible(achievementRow{PlayerID: pid, Key: domain.EfficientKey, Kind: string(domain.AchVolume),
				EarnedAt: today, Meta: map[string]string{"pct": fmt.Sprint(domain.EfficientPct), "min": fmt.Sprint(domain.EfficientMin)}})
		}
	}

	// ── Kehadiran: sessions + streak (career & per season) ────────────────
	if err := s.backfillAttendance(ctx, sessions, sessionIdx, seasonSessions, seasonByID, addMedal, addSeasonMedal, addCollectible); err != nil {
		return BackfillResult{}, err
	}

	// ── Sosial + rekor (partner, lawan, margin, partner terbaik) ──────────
	if err := s.backfillSocialRecords(ctx, addMedal, addCollectible); err != nil {
		return BackfillResult{}, err
	}

	// ── Turnamen (partisipasi, juara, podium, medal count) ────────────────
	if err := s.backfillTournaments(ctx, addMedal, addCollectible); err != nil {
		return BackfillResult{}, err
	}

	// ── Rank akhir season (juara/podium collectible) ──────────────────────
	if err := s.backfillSeasonRank(ctx, addCollectible); err != nil {
		return BackfillResult{}, err
	}

	medCount, err := s.insertAchievements(ctx, medals, true)
	if err != nil {
		return BackfillResult{}, err
	}
	colCount, err := s.insertAchievements(ctx, collectibles, false)
	if err != nil {
		return BackfillResult{}, err
	}
	return BackfillResult{Medals: medCount, Collectibles: colCount}, nil
}

func firstDateAt(cks []checkpoint, threshold int64, fallback string) string {
	for _, c := range cks {
		if c.value >= threshold {
			return c.date
		}
	}
	return fallback
}

func lastSeasonID(entries []seasonEntry) string {
	if len(entries) == 0 {
		return ""
	}
	return entries[len(entries)-1].seasonID
}

func mustMedal(id string) domain.MedalDef {
	d, _ := domain.MedalByID(id)
	return d
}

func mustSeasonMedal(id string) domain.MedalDef {
	d, _ := domain.SeasonMedalByID(id)
	return d
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

// ── Kehadiran ─────────────────────────────────────────────────────────────

func (s *SessionStore) backfillAttendance(
	ctx context.Context,
	sessions []sessionInfo,
	sessionIdx map[string]int,
	seasonSessions map[string][]sessionInfo,
	seasonByID map[string]seasonInfo,
	addMedal func(string, domain.MedalDef, int64, string, string, map[string]string),
	addSeasonMedal func(string, string, string, domain.MedalDef, int64, string),
	addCollectible func(achievementRow),
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

	today := todayDate()
	for pid, list := range byPlayer {
		attended := map[string]bool{}
		seen := map[string]bool{}
		for _, a := range list {
			if seen[a.sessionID] {
				continue
			}
			seen[a.sessionID] = true
			if !a.absent {
				attended[a.sessionID] = true
			}
		}

		// career sessions + streak
		var sessionCk, streakCk []checkpoint
		count := int64(0)
		run, runMax := int64(0), int64(0)
		for _, sess := range sessions {
			if attended[sess.ID] {
				count++
				run++
				sessionCk = append(sessionCk, checkpoint{value: count, date: sess.Date})
			} else {
				run = 0
			}
			if run > runMax {
				runMax = run
			}
			streakCk = append(streakCk, checkpoint{value: run, date: sess.Date})
		}
		sessionDef := mustMedal("sessions")
		addMedal(pid, sessionDef, count, "", firstDateAt(sessionCk, sessionDef.Thresholds[0], today), nil)
		streakDef := mustMedal("streak")
		addMedal(pid, streakDef, runMax, "", firstDateAt(streakCk, streakDef.Thresholds[0], today), nil)

		// season sessions + streak
		for sid, sSessions := range seasonSessions {
			if len(sSessions) == 0 {
				continue
			}
			var sCount, sRun, sRunMax int64
			var sCk, sStreakCk []checkpoint
			for _, sess := range sSessions {
				if attended[sess.ID] {
					sCount++
					sRun++
					sCk = append(sCk, checkpoint{value: sCount, date: sess.Date})
				} else {
					sRun = 0
				}
				if sRun > sRunMax {
					sRunMax = sRun
				}
				sStreakCk = append(sStreakCk, checkpoint{value: sRun, date: sess.Date})
			}
			name := seasonByID[sid].Name
			end := sSessions[len(sSessions)-1].Date
			sessDef := mustSeasonMedal("sessions")
			addSeasonMedal(pid, sid, name, sessDef, sCount, firstDateAt(sCk, sessDef.Thresholds[0], end))
			skDef := mustSeasonMedal("streak")
			addSeasonMedal(pid, sid, name, skDef, sRunMax, firstDateAt(sStreakCk, skDef.Thresholds[0], end))
		}
	}
	return nil
}

// ── Sosial + rekor ────────────────────────────────────────────────────────

func (s *SessionStore) backfillSocialRecords(
	ctx context.Context,
	addMedal func(string, domain.MedalDef, int64, string, string, map[string]string),
	addCollectible func(achievementRow),
) error {
	today := todayDate()
	// partner & lawan berbeda
	for _, spec := range []struct {
		joinCond string
		medalID  string
	}{{
		joinCond: "tl.team = sgp.team AND tl.session_player_internal_id <> sp.internal_id",
		medalID:  "partners",
	}, {
		joinCond: "tl.team <> sgp.team",
		medalID:  "opponents",
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
			addMedal(pid, mustMedal(spec.medalID), n, "", today, nil)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
	}

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
			addMedal(pid, mustMedal("margin"), margin, "", today, nil)
		}
		if perfect {
			addCollectible(achievementRow{PlayerID: pid, Key: domain.PerfectKey, Kind: string(domain.AchVolume), EarnedAt: today, Value: i64(1)})
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	// partner terbaik
	pRows, err := s.pool.Query(ctx, `
		SELECT sp.player_id::text, count(*)::int
		FROM `+s.schema+`.session_players sp
		JOIN `+s.schema+`.scheduled_game_players sgp ON sgp.session_player_internal_id = sp.internal_id
		JOIN `+s.schema+`.scheduled_games sg ON sg.internal_id = sgp.scheduled_game_internal_id AND sg.session_id = sp.session_id
		JOIN `+s.schema+`.scheduled_game_players tl ON tl.scheduled_game_internal_id = sg.internal_id
			AND tl.team = sgp.team AND tl.session_player_internal_id <> sp.internal_id
		JOIN `+s.schema+`.session_players tsp ON tsp.internal_id = tl.session_player_internal_id
		WHERE sp.player_id IS NOT NULL AND tsp.player_id IS NOT NULL AND sp.is_absent = false
		  AND sg.score_a IS NOT NULL AND sg.score_b IS NOT NULL
		GROUP BY 1,2`)
	if err != nil {
		return err
	}
	best := map[string]int64{}
	for pRows.Next() {
		var (
			pid, partner string
			n            int64
		)
		if err := pRows.Scan(&pid, &partner, &n); err != nil {
			pRows.Close()
			return err
		}
		if n > best[pid] {
			best[pid] = n
		}
	}
	pRows.Close()
	if err := pRows.Err(); err != nil {
		return err
	}
	for pid, n := range best {
		addMedal(pid, mustMedal("top_partner"), n, "", today, nil)
	}
	return nil
}

// ── Turnamen ──────────────────────────────────────────────────────────────

func (s *SessionStore) backfillTournaments(
	ctx context.Context,
	addMedal func(string, domain.MedalDef, int64, string, string, map[string]string),
	addCollectible func(achievementRow),
) error {
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
	medalDef := mustMedal("tournaments")
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
		for i, p := range ordered {
			addCollectible(achievementRow{PlayerID: pid, Key: domain.TournamentKey(p.tid), Kind: string(domain.AchTournament),
				EarnedAt: p.date, Meta: map[string]string{"name": p.name}})
			if int64(i+1) == medalDef.Thresholds[0] {
				addMedal(pid, medalDef, int64(len(ordered)), "", p.date, nil)
			}
		}
		if int64(len(ordered)) >= medalDef.Thresholds[0] {
			addMedal(pid, medalDef, int64(len(ordered)), "", ordered[0].date, nil)
		}
	}

	// juara/podium classic + team
	pairPlayers, err := s.loadPairPlayers(ctx)
	if err != nil {
		return err
	}
	teamPlayers, err := s.loadTeamPlayers(ctx)
	if err != nil {
		return err
	}
	if err := s.appendClassicFinals(ctx, addCollectible, pairPlayers); err != nil {
		return err
	}
	return s.appendTeamFinals(ctx, addCollectible, teamPlayers)
}

func (s *SessionStore) appendClassicFinals(ctx context.Context, add func(achievementRow), pairPlayers map[string][]string) error {
	rows, err := s.pool.Query(ctx, `
		SELECT tm.tournament_id::text, t.name, t.event_date::text, tm.phase,
		       tm.pair_a_id::text, tm.pair_b_id::text, tm.score_a, tm.score_b
		FROM `+s.schema+`.tournament_matches tm
		JOIN `+s.schema+`.tournaments t ON t.id = tm.tournament_id
		WHERE tm.phase IN ('final','3rd') AND tm.score_a IS NOT NULL AND tm.score_b IS NOT NULL
		  AND tm.pair_a_id IS NOT NULL AND tm.pair_b_id IS NOT NULL`)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			tid, name, date, phase, pa, pb string
			sa, sb                         int
		)
		if err := rows.Scan(&tid, &name, &date, &phase, &pa, &pb, &sa, &sb); err != nil {
			return err
		}
		winner, loser := pa, pb
		if sb > sa {
			winner, loser = pb, pa
		}
		winnerKey, loserKey := domain.ChampionKey(tid), domain.PodiumKey(tid)
		if phase == "3rd" {
			winnerKey = domain.PodiumKey(tid)
		}
		for _, pid := range pairPlayers[winner] {
			add(achievementRow{PlayerID: pid, Key: winnerKey, Kind: string(domain.AchTournament),
				EarnedAt: date, Meta: map[string]string{"name": name}})
		}
		if phase == "final" {
			for _, pid := range pairPlayers[loser] {
				add(achievementRow{PlayerID: pid, Key: loserKey, Kind: string(domain.AchTournament),
					EarnedAt: date, Meta: map[string]string{"name": name}})
			}
		}
	}
	return rows.Err()
}

func (s *SessionStore) appendTeamFinals(ctx context.Context, add func(achievementRow), teamPlayers map[string][]string) error {
	rows, err := s.pool.Query(ctx, `
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
	defer rows.Close()
	for rows.Next() {
		var (
			tid, name, date, ta, tb string
			wa, wb                  int
		)
		if err := rows.Scan(&tid, &name, &date, &ta, &tb, &wa, &wb); err != nil {
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
	return rows.Err()
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

// ── Rank akhir season ─────────────────────────────────────────────────────

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
		pid, name, end string
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

func i64(n int) *int64 {
	v := int64(n)
	return &v
}
