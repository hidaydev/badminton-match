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
	Note       string            `json:"note,omitempty"` // deskripsi singkat (milestone)
	Value      *int64            `json:"value,omitempty"`
	TierLevel  int               `json:"tierLevel,omitempty"`  // 1..5 untuk medal, 0 untuk event
	TierName   string            `json:"tierName,omitempty"`   // Bronze..Onyx
	NextTarget *int64            `json:"nextTarget,omitempty"` // ambang tingkat berikutnya
	Thresholds []int64           `json:"thresholds,omitempty"` // tangga ambang 1..5
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
		       COALESCE(pa.meta::text, '{}')
		FROM `+s.schema+`.player_achievements pa
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
		if err := rows.Scan(&v.Key, &v.Kind, &value, &v.EarnedAt, &metaRaw); err != nil {
			return nil, err
		}
		v.Value = value
		v.Meta = map[string]string{}
		_ = json.Unmarshal([]byte(metaRaw), &v.Meta)
		if title, unit, def, ok := domain.TitleForMedal(v.Key); ok {
			level := int64(0)
			if value != nil {
				level = int64(domain.TierForValue(def, *value))
			}
			v.Title = title
			v.Note = def.Note
			v.Thresholds = def.Thresholds[:]
			v.TierLevel = int(level)
			v.TierName = domain.TierName(int(level))
			if next, has := domain.NextTarget(def, int(level)); has {
				v.NextTarget = &next
			}
			if value != nil {
				v.Detail = fmt.Sprintf("%d %s", *value, unit)
			}
		} else {
			v.Title, v.Detail = domain.DescribeCollectible(v.Key, v.Meta)
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
			(player_id, achievement_key, kind, earned_at, value, meta) VALUES `)
		for j, r := range rows[i:end] {
			if j > 0 {
				sb.WriteString(", ")
			}
			b := len(args)
			sb.WriteString(fmt.Sprintf("($%d::uuid,$%d,$%d,$%d::date,$%d,$%d::jsonb)",
				b+1, b+2, b+3, b+4, b+5, b+6))
			meta, _ := json.Marshal(r.Meta)
			var value any
			if r.Value != nil {
				value = *r.Value
			}
			args = append(args, r.PlayerID, r.Key, r.Kind, r.EarnedAt, value, string(meta))
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

type sessionInfo struct {
	ID   string
	Date string
}

type seasonEntry struct {
	endDate     string
	games, wins int64
}

type checkpoint struct {
	value int64
	date  string
}

// BackfillAchievements — bangun ulang medal + collectible dari data historis.
// Idempoten.
func (s *SessionStore) BackfillAchievements(ctx context.Context) (BackfillResult, error) {
	sessions, _, err := s.loadSessions(ctx)
	if err != nil {
		return BackfillResult{}, err
	}
	current, err := s.loadCurrentRatings(ctx)
	if err != nil {
		return BackfillResult{}, err
	}

	today := todayDate()
	ordered := map[string][]seasonEntry{}
	for pid, c := range current {
		ordered[pid] = append(ordered[pid], seasonEntry{
			endDate: today, games: c.games, wins: c.wins,
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
	addMedal := func(pid string, def domain.MedalDef, value int64, earnedAt string, meta map[string]string) {
		if value < def.Thresholds[0] {
			return
		}
		v := value
		medals = append(medals, achievementRow{
			PlayerID: pid, Key: domain.MedalKey(def.ID), Kind: string(def.Kind),
			EarnedAt: earnedAt, Value: &v, Meta: meta,
		})
	}

	// ── Medali career yang sifatnya kumulatif / max dari data season ──────
	for pid, entries := range ordered {
		if len(entries) == 0 {
			continue
		}
		// Medal season & Peak Rating sudah dihapus bersama pensiunnya season dan
		// Glicko (2026-09-29): season tidak lagi punya siklus, dan rating tidak
		// lagi dihitung sehingga ambang 2000 mustahil dicapai. Baris lama di
		// player_achievements ikut dihapus lewat migration.
		var (
			gamesCk, winsCk []checkpoint
			games, wins     int64
		)
		for _, e := range entries {
			games += e.games
			wins += e.wins
			if e.games > 0 || e.wins > 0 {
				gamesCk = append(gamesCk, checkpoint{value: games, date: e.endDate})
				winsCk = append(winsCk, checkpoint{value: wins, date: e.endDate})
			}
		}
		// season_id tidak lagi diisi: season pensiun bersama Glicko, jadi medal
		// games/wins tidak punya konteks musim.
		addMedal(pid, mustMedal("games"), games, firstDateAt(gamesCk, mustMedal("games").Thresholds[0], today), nil)
		addMedal(pid, mustMedal("wins"), wins, firstDateAt(winsCk, mustMedal("wins").Thresholds[0], today), nil)
	}

	// ── Kehadiran: sessions + streak (career) ─────────────────────────────
	if err := s.backfillAttendance(ctx, sessions, addMedal, addCollectible); err != nil {
		return BackfillResult{}, err
	}

	// ── Sosial (partner & lawan unik) ─────────────────────────────────────
	if err := s.backfillSocialRecords(ctx, addMedal); err != nil {
		return BackfillResult{}, err
	}

	// ── Event: partisipasi turnamen ───────────────────────────────────────
	if err := s.backfillTournaments(ctx, addCollectible); err != nil {
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

func mustMedal(id string) domain.MedalDef {
	d, _ := domain.MedalByID(id)
	return d
}

// ── Loader helpers ────────────────────────────────────────────────────────

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

type currentRating struct {
	sticky              string
	games, wins, losses int64
}

func (s *SessionStore) loadCurrentRatings(ctx context.Context) (map[string]currentRating, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT rp.player_id::text, COALESCE(p.tier, ''),
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
		if err := rows.Scan(&pid, &c.sticky, &c.games, &c.wins, &c.losses); err != nil {
			return nil, err
		}
		out[pid] = c
	}
	return out, rows.Err()
}

// ── Kehadiran ─────────────────────────────────────────────────────────────

func (s *SessionStore) backfillAttendance(
	ctx context.Context,
	sessions []sessionInfo,
	addMedal func(string, domain.MedalDef, int64, string, map[string]string),
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
		addMedal(pid, sessionDef, count, firstDateAt(sessionCk, sessionDef.Thresholds[0], today), nil)
		streakDef := mustMedal("streak")
		addMedal(pid, streakDef, runMax, firstDateAt(streakCk, streakDef.Thresholds[0], today), nil)
	}
	return nil
}

// ── Sosial + rekor ────────────────────────────────────────────────────────

func (s *SessionStore) backfillSocialRecords(
	ctx context.Context,
	addMedal func(string, domain.MedalDef, int64, string, map[string]string),
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
			addMedal(pid, mustMedal(spec.medalID), n, today, nil)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
	}

	return nil
}

// ── Turnamen ──────────────────────────────────────────────────────────────

func (s *SessionStore) backfillTournaments(
	ctx context.Context,
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
			addCollectible(achievementRow{PlayerID: pid, Key: domain.TournamentKey(p.tid), Kind: string(domain.AchTournament),
				EarnedAt: p.date, Meta: map[string]string{"name": p.name}})
		}
	}
	return nil
}

// ── util ──────────────────────────────────────────────────────────────────

func todayDate() string {
	return time.Now().Format("2006-01-02")
}
